#!/usr/bin/env python3
"""
Convert a HuggingFace Whisper model to MLX format for use with mlx_whisper.
Based on mlx-examples/whisper/convert.py (Apple Inc.)

Usage:
    python convert.py --hf-path MediaTek-Research/Breeze-ASR-25 --mlx-path ~/models/breeze-asr-25-mlx
"""
import argparse
import copy
import hashlib
import importlib.metadata
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from dataclasses import asdict
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import torch
from mlx.utils import tree_flatten, tree_map, tree_unflatten
from mlx_whisper import torch_whisper
from mlx_whisper.whisper import ModelDimensions, Whisper

from model_validation import (
    ModelValidationError,
    MODEL_MANIFEST,
    publish_staged_artifact,
    verify_files,
)


SOURCE_SPEC = MODEL_MANIFEST["conversion_sources"]["breeze-asr-25-canonical"]


def hf_to_pt(weights, config):
    """Map HuggingFace Transformers weight names to OpenAI Whisper weight names."""
    config = {
        "n_mels": config["num_mel_bins"],
        "n_audio_ctx": config["max_source_positions"],
        "n_audio_state": config["d_model"],
        "n_audio_head": config["encoder_attention_heads"],
        "n_audio_layer": config["encoder_layers"],
        "n_vocab": config["vocab_size"],
        "n_text_ctx": config["max_target_positions"],
        "n_text_state": config["d_model"],
        "n_text_head": config["decoder_attention_heads"],
        "n_text_layer": config["decoder_layers"],
    }

    def remap(k):
        k = k.replace("model.", "")
        k = k.replace(".layers", ".blocks")
        k = k.replace(".self_attn", ".attn")
        k = k.replace(".attn_layer_norm", ".attn_ln")
        k = k.replace(".encoder_attn.", ".cross_attn.")
        k = k.replace(".encoder_attn_layer_norm", ".cross_attn_ln")
        k = k.replace(".final_layer_norm", ".mlp_ln")
        k = k.replace(".q_proj", ".query")
        k = k.replace(".k_proj", ".key")
        k = k.replace(".v_proj", ".value")
        k = k.replace(".out_proj", ".out")
        k = k.replace(".fc1", ".mlp1")
        k = k.replace(".fc2", ".mlp2")
        k = k.replace("embed_positions.weight", "positional_embedding")
        k = k.replace("decoder.embed_tokens", "decoder.token_embedding")
        k = k.replace("encoder.layer_norm", "encoder.ln_post")
        k = k.replace("decoder.layer_norm", "decoder.ln")
        return k

    # token embeddings are shared with output projection
    weights.pop("proj_out.weight", None)
    weights = {remap(k): v for k, v in weights.items()}
    return weights, config


def load_hf_weights(hf_path: str):
    """Download a fixed Breeze revision and verify its trusted Hub metadata."""
    from huggingface_hub import snapshot_download

    if hf_path != SOURCE_SPEC["repo_id"]:
        raise ValueError(f"Only the pinned source {SOURCE_SPEC['repo_id']} is supported")
    revision = SOURCE_SPEC["revision"]
    print(f"[INFO] Downloading {hf_path}@{revision} from Hugging Face...", flush=True)
    local_path = snapshot_download(
        repo_id=hf_path,
        revision=revision,
        allow_patterns=list(SOURCE_SPEC["required_files"].keys()),
    )
    local_path = Path(local_path)
    if local_path.name != revision:
        raise ModelValidationError(
            f"Downloaded source revision {local_path.name}; expected {revision}"
        )
    verify_files(local_path, SOURCE_SPEC["required_files"])
    sf_path = local_path / "model.safetensors"
    print("[INFO] Loading verified model.safetensors...", flush=True)
    from safetensors.torch import load_file
    weights = load_file(str(sf_path))
    with open(local_path / "config.json") as f:
        config = json.load(f)

    return weights, config, local_path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tool_version(package: str, fallback: str | None = None) -> str:
    try:
        return importlib.metadata.version(package)
    except importlib.metadata.PackageNotFoundError:
        if fallback:
            return fallback
        raise RuntimeError(f"Could not read installed {package} version")


def _write_conversion_manifest(output: Path, dtype_str: str) -> dict:
    files = {}
    for name in ("config.json", "weights.safetensors"):
        path = output / name
        files[name] = {"size": path.stat().st_size, "sha256": sha256_file(path)}
    manifest = {
        "format": "typelessmlx-conversion-v1",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source": {
            "repo_id": SOURCE_SPEC["repo_id"],
            "revision": SOURCE_SPEC["revision"],
            "trusted_files": SOURCE_SPEC["required_files"],
        },
        "conversion": {
            "dtype": dtype_str,
            "parameters": {
                "source_format": "Hugging Face Transformers safetensors",
                "mapping": "hf_to_pt v1",
                "convolution_layout": "(out,in,k) to (out,k,in)",
                "encoder_positional_embedding": "computed by mlx_whisper and omitted from saved source weights",
            },
            "tools": {
                "mlx": tool_version("mlx"),
                "mlx_whisper": tool_version("mlx-whisper", getattr(torch_whisper, "__version__", None)),
                "torch": str(torch.__version__),
            },
        },
        "outputs": files,
    }
    manifest_path = output / "conversion_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return manifest


def convert_hf_to_mlx(hf_path: str, mlx_path: str, dtype_str: str = "float16"):
    """Convert the pinned Breeze source into a staged, loader-checked artifact."""
    if dtype_str not in {"float16", "float32"}:
        raise ValueError("dtype must be float16 or float32")
    dtype = mx.float16 if dtype_str == "float16" else mx.float32

    target = Path(os.path.expanduser(mlx_path)).resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{target.name}.stage-", dir=target.parent))
    try:
        return _convert_to_staging(hf_path, target, staging, dtype_str, dtype)
    except Exception:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        raise


def _convert_to_staging(hf_path: str, target: Path, mlx_path: Path, dtype_str: str, dtype):

    def remap_weight(key, value):
        # mlx_whisper uses mlp1/mlp2 directly (not mlp.0/mlp.2)
        # Conv1d: PyTorch (out, in, k) → MLX (out, k, in)
        if "conv" in key and hasattr(value, "ndim") and value.ndim == 3:
            if isinstance(value, torch.Tensor):
                value = value.permute(0, 2, 1)
            else:
                value = value.swapaxes(1, 2)
        if isinstance(value, torch.Tensor):
            value = mx.array(value.detach().float().numpy())
        elif not isinstance(value, mx.array):
            value = mx.array(value)
        return key, value.astype(dtype)

    # Load HF weights
    raw_weights, hf_config, source_path = load_hf_weights(hf_path)

    # Map to OpenAI/MLX weight names
    print("[INFO] Remapping weight names...", flush=True)
    weights, mlx_config = hf_to_pt(raw_weights, hf_config)

    # Remove positional embedding (computed, not stored)
    weights.pop("encoder.positional_embedding", None)

    model_dims = ModelDimensions(**mlx_config)
    model = Whisper(model_dims, dtype)
    expected_params = dict(tree_flatten(model.parameters()))
    expected_keys = set(expected_params)
    converted_keys = set(weights)
    missing = sorted(expected_keys - converted_keys)
    unexpected = sorted(converted_keys - expected_keys)
    if missing or unexpected:
        raise ModelValidationError(
            f"Converted weight keys do not match model structure; missing={missing[:8]}, unexpected={unexpected[:8]}"
        )

    # Convert weights: rename mlp + transpose conv
    print("[INFO] Converting weights to MLX format...", flush=True)
    mlx_weights = {}
    for k, v in weights.items():
        new_k, new_v = remap_weight(k, v)
        mlx_weights[new_k] = new_v

    # Load every mapped tensor before writing an artifact.
    print("[INFO] Verifying model structure...", flush=True)
    model.load_weights(list(mlx_weights.items()), strict=True)

    # Final weights from model
    final_weights = dict(tree_flatten(model.parameters()))

    # Save
    mlx_path.mkdir(parents=True, exist_ok=True)

    print(f"[INFO] Saving to {mlx_path}...", flush=True)

    # Save as weights.safetensors (required by mlx_whisper load_models.py)
    mx.save_safetensors(str(mlx_path / "weights.safetensors"), final_weights)

    # Also save config.json
    config_out = dict(mlx_config)
    config_out["model_type"] = "whisper"
    with open(mlx_path / "config.json", "w") as f:
        json.dump(config_out, f, indent=4)

    print(f"[INFO] Saved weights.safetensors and config.json to {mlx_path}", flush=True)
    conversion_manifest = _write_conversion_manifest(mlx_path, dtype_str)
    verify_files(
        mlx_path,
        {
            name: {"size": details["size"], "algorithm": "sha256", "digest": details["sha256"]}
            for name, details in conversion_manifest["outputs"].items()
        },
    )

    print("[INFO] Reloading staged artifact through mlx_whisper loader...", flush=True)
    from mlx_whisper.load_models import load_model
    reloaded = load_model(str(mlx_path), dtype=dtype)
    del reloaded
    try:
        mx.clear_cache()
    except AttributeError:
        pass

    # Keep the manifest's source metadata tied to the verified downloaded snapshot.
    if source_path.name != SOURCE_SPEC["revision"]:
        raise ModelValidationError("Verified Breeze source snapshot changed during conversion")
    publish_staged_artifact(mlx_path, target)
    print(f"[INFO] Published verified model to {target}", flush=True)
    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert HuggingFace Whisper model to MLX format")
    parser.add_argument("--hf-path", required=True, help="HuggingFace model repo ID")
    parser.add_argument("--mlx-path", required=True, help="Output MLX model directory")
    parser.add_argument("--dtype", default="float16", choices=["float16", "float32"],
                        help="Weight dtype (default: float16)")
    args = parser.parse_args()

    mlx_path = os.path.expanduser(args.mlx_path)

    try:
        success = convert_hf_to_mlx(args.hf_path, mlx_path, args.dtype)
        print(f"\n✅ Conversion complete! Model saved to: {mlx_path}", flush=True)
        sys.exit(0)
    except Exception as e:
        import traceback
        print(f"\n❌ Conversion failed: {e}", file=sys.stderr, flush=True)
        traceback.print_exc()
        sys.exit(1)
