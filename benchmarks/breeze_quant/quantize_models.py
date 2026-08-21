#!/usr/bin/env python3
"""Build and validate quantized Breeze-ASR-25 MLX artifacts.

The artifacts written by this script use the quantization metadata understood by
``mlx-whisper==0.4.3``.  Quantization is weight-only affine quantization with
``group_size=64``; no convolution or normalization layers are quantized.

Variants and their exact module predicates are deliberately kept here (rather
than inferred from filenames) so that a generated artifact can be audited from
its ``quantization_manifest.json``:

* ``8bit``: ``isinstance(module, (nn.Linear, nn.Embedding))``;
* ``6bit``: ``isinstance(module, (nn.Linear, nn.Embedding))``;
* ``hybrid``: ``isinstance(module, nn.Linear) and path.startswith("encoder.")``.

The hybrid predicate therefore quantizes the 192 encoder Linear modules only;
the 320 decoder Linear modules, decoder Embedding, convolution layers, and
normalization layers remain FP16.  The 8-bit and 6-bit variants quantize all
512 Linear modules and the one decoder Embedding.

Each variant is produced in a temporary sibling directory, reloaded through
``mlx_whisper.load_models.load_model`` (the loader module used by
mlx-whisper 0.4.3), and exercised with a short silent-audio transcription
smoke test before being renamed to its final artifact directory.  A manifest
records logical parameter sizes, file sizes, SHA-256 hashes, module counts,
the exact predicate/configuration, command, and any smoke-test errors.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import shlex
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Callable, Iterable

import mlx.core as mx
import mlx.nn as nn
import mlx_whisper
import numpy as np
from mlx.utils import tree_flatten
from mlx_whisper.load_models import load_model


DEFAULT_SOURCE = Path.home() / ".local/share/typelessmlx/models/breeze-asr-25-mlx"
VARIANTS = (
    {
        "name": "8bit",
        "bits": 8,
        "predicate_description": "isinstance(module, (nn.Linear, nn.Embedding))",
        "predicate": lambda path, module: isinstance(module, (nn.Linear, nn.Embedding)),
    },
    {
        "name": "6bit",
        "bits": 6,
        "predicate_description": "isinstance(module, (nn.Linear, nn.Embedding))",
        "predicate": lambda path, module: isinstance(module, (nn.Linear, nn.Embedding)),
    },
    {
        "name": "hybrid",
        "bits": 6,
        "predicate_description": 'isinstance(module, nn.Linear) and path.startswith("encoder.")',
        "predicate": lambda path, module: isinstance(module, nn.Linear)
        and path.startswith("encoder."),
    },
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        type=Path,
        default=DEFAULT_SOURCE,
        help="Existing FP16 MLX model directory (default: %(default)s)",
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=None,
        help="Directory containing artifact directories (default: source parent)",
    )
    parser.add_argument(
        "--no-smoke-test",
        action="store_true",
        help="Skip the transcription smoke test (not recommended)",
    )
    parser.add_argument(
        "--replace-generated",
        action="store_true",
        help="Replace existing artifact directories (requires explicit opt-in)",
    )
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(16 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def release_mlx_memory() -> None:
    """Release Python and MLX references between sequential variants."""

    gc.collect()
    if hasattr(mx, "clear_cache"):
        mx.clear_cache()


def flatten_parameters(model: nn.Module) -> dict[str, mx.array]:
    return dict(tree_flatten(model.parameters()))


def module_type_counts(model: nn.Module) -> tuple[Counter[str], list[str]]:
    leaves = tree_flatten(
        model.leaf_modules(),
        is_leaf=nn.Module.is_module,
    )
    counts: Counter[str] = Counter()
    quantized_paths: list[str] = []
    for path, module in leaves:
        counts[type(module).__name__] += 1
        if isinstance(module, (nn.QuantizedLinear, nn.QuantizedEmbedding)):
            quantized_paths.append(path)
    return counts, sorted(quantized_paths)


def dtype_and_size_summary(
    parameters: dict[str, mx.array],
) -> tuple[int, dict[str, int], dict[str, int]]:
    logical_bytes = 0
    bytes_by_dtype: Counter[str] = Counter()
    count_by_dtype: Counter[str] = Counter()
    for value in parameters.values():
        if not hasattr(value, "nbytes"):
            continue
        nbytes = int(value.nbytes)
        dtype = str(value.dtype)
        logical_bytes += nbytes
        bytes_by_dtype[dtype] += nbytes
        count_by_dtype[dtype] += 1
    return logical_bytes, dict(bytes_by_dtype), dict(count_by_dtype)


def safetensor_summary(path: Path) -> dict[str, object]:
    """Inspect only the safetensors header to verify packed quantized fields."""

    # ``safe_open`` is imported lazily so this script's model-building imports
    # remain the same as the app's mlx-whisper environment.
    from safetensors import safe_open

    with safe_open(str(path), framework="numpy") as handle:
        keys = list(handle.keys())
        scales = sorted(key[: -len(".scales")] for key in keys if key.endswith(".scales"))
        packed_weights = sorted(
            key[: -len(".weight")]
            for key in keys
            if key.endswith(".weight")
            and key.rsplit(".", 1)[0] in scales
        )
    return {
        "tensor_count": len(keys),
        "scales_tensor_count": len(scales),
        "packed_weight_module_count": len(packed_weights),
        "scale_module_paths": scales,
    }


def smoke_test(path: Path, model: nn.Module) -> dict[str, object]:
    """Run one deterministic short transcription using the already-loaded model."""

    # mlx_whisper.transcribe caches models in ModelHolder.  Point that cache at
    # the model loaded above so the smoke test both uses this exact artifact and
    # avoids loading a second multi-gigabyte model in the same process.
    import importlib

    transcribe_module = importlib.import_module("mlx_whisper.transcribe")
    transcribe_module.ModelHolder.model = model
    transcribe_module.ModelHolder.model_path = str(path)

    duration = 0.5
    audio = np.zeros(int(16000 * duration), dtype=np.float32)
    started = time.monotonic()
    result = mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=str(path),
        language="zh",
        task="transcribe",
        temperature=0.0,
        sample_len=8,
        condition_on_previous_text=False,
        compression_ratio_threshold=None,
        logprob_threshold=None,
        no_speech_threshold=0.6,
        clip_timestamps=f"0,{duration}",
        verbose=False,
    )
    return {
        "audio_seconds": duration,
        "elapsed_seconds": time.monotonic() - started,
        "text": result.get("text", ""),
        "segment_count": len(result.get("segments", [])),
        "language": result.get("language"),
    }


def build_variant(
    variant: dict[str, object],
    source: Path,
    output_root: Path,
    source_info: dict[str, object],
    command: str,
    run_smoke_test: bool,
    replace_generated: bool,
) -> dict[str, object]:
    name = str(variant["name"])
    bits = int(variant["bits"])
    output = output_root / f"breeze-asr-25-mlx-{name}"
    if output.exists():
        if not replace_generated:
            raise FileExistsError(
                f"Refusing to overwrite existing artifact; use --replace-generated "
                f"only for an intentional rebuild: {output}"
            )
        import shutil

        shutil.rmtree(output)

    output_root.mkdir(parents=True, exist_ok=True)
    temporary = output_root / f".{output.name}.tmp-{int(time.time() * 1_000_000)}"
    temporary.mkdir()
    weights_path = temporary / "weights.safetensors"
    config_path = temporary / "config.json"
    manifest_path = temporary / "quantization_manifest.json"

    quantization = {"group_size": 64, "bits": bits, "mode": "affine"}
    selected_paths: list[str] = []
    errors: list[str] = []
    model: nn.Module | None = None
    reloaded: nn.Module | None = None

    try:
        print(f"[{name}] loading FP16 source: {source}", flush=True)
        started = time.monotonic()
        model = load_model(str(source), dtype=mx.float16)
        load_seconds = time.monotonic() - started

        def predicate(path: str, module: nn.Module) -> bool:
            should_quantize = bool(variant["predicate"](path, module))
            if should_quantize:
                selected_paths.append(path)
            return should_quantize

        print(
            f"[{name}] quantizing bits={bits} group_size=64 mode=affine "
            f"predicate={variant['predicate_description']}",
            flush=True,
        )
        started = time.monotonic()
        nn.quantize(
            model,
            group_size=64,
            bits=bits,
            mode="affine",
            class_predicate=predicate,
        )
        quantize_seconds = time.monotonic() - started
        selected_paths = sorted(selected_paths)

        parameters = flatten_parameters(model)
        # Quantization returns concrete arrays on this MLX release, but eval is
        # explicit here so the saved file's byte accounting is deterministic.
        mx.eval(*parameters.values())
        logical_bytes, bytes_by_dtype, count_by_dtype = dtype_and_size_summary(parameters)
        print(
            f"[{name}] saving {len(parameters)} tensors, "
            f"{logical_bytes:,} logical bytes to {weights_path}",
            flush=True,
        )
        mx.save_safetensors(str(weights_path), parameters)

        config = json.loads((source / "config.json").read_text())
        config.pop("quantization", None)
        config["model_type"] = "whisper"
        config["quantization"] = quantization
        config_path.write_text(json.dumps(config, indent=4) + "\n")

        file_summary = {
            "weights_file_bytes": weights_path.stat().st_size,
            "weights_sha256": sha256_file(weights_path),
            "config_file_bytes": config_path.stat().st_size,
            "config_sha256": sha256_file(config_path),
        }
        tensor_summary = safetensor_summary(weights_path)

        # Drop the builder model before loading the saved artifact.  This keeps
        # the three required variants strictly sequential in a 24 GB process.
        del parameters
        del model
        model = None
        release_mlx_memory()

        print(f"[{name}] reloading saved artifact with mlx-whisper 0.4.3", flush=True)
        started = time.monotonic()
        reloaded = load_model(str(temporary), dtype=mx.float16)
        reload_seconds = time.monotonic() - started
        reloaded_type_counts, reloaded_quantized_paths = module_type_counts(reloaded)

        if reloaded_quantized_paths != selected_paths:
            raise RuntimeError(
                "reload quantized-module paths differ from build predicate: "
                f"built={len(selected_paths)} reloaded={len(reloaded_quantized_paths)}"
            )
        if tensor_summary["scales_tensor_count"] != len(selected_paths):
            raise RuntimeError(
                "saved safetensors scales count differs from selected modules: "
                f"scales={tensor_summary['scales_tensor_count']} selected={len(selected_paths)}"
            )

        smoke_result: dict[str, object] | None = None
        if run_smoke_test:
            try:
                print(f"[{name}] running short transcription smoke test", flush=True)
                smoke_result = smoke_test(temporary, reloaded)
                print(
                    f"[{name}] smoke text={smoke_result['text']!r} "
                    f"elapsed={smoke_result['elapsed_seconds']:.2f}s",
                    flush=True,
                )
            except Exception as exc:  # Preserve a usable artifact and record the error.
                error = f"smoke_test: {type(exc).__name__}: {exc}"
                errors.append(error)
                print(f"[{name}] ERROR {error}", file=sys.stderr, flush=True)

        manifest = {
            "artifact": output.name,
            "source_model": source_info,
            "mlx_whisper_version": mlx_whisper.__version__,
            "loader": "mlx_whisper.load_models.load_model",
            "quantization": quantization,
            "predicate": variant["predicate_description"],
            "selected_module_count": len(selected_paths),
            "selected_module_paths": selected_paths,
            "module_type_counts_after_reload": dict(sorted(reloaded_type_counts.items())),
            "logical_parameter_bytes": logical_bytes,
            "logical_bytes_by_dtype": bytes_by_dtype,
            "tensor_count_by_dtype": count_by_dtype,
            "safetensors": tensor_summary,
            "files": file_summary,
            "build_elapsed_seconds": load_seconds + quantize_seconds,
            "reload_elapsed_seconds": reload_seconds,
            "smoke_test": smoke_result,
            "errors": errors,
            "command": command,
        }
        manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

        del reloaded
        reloaded = None
        release_mlx_memory()
        temporary.rename(output)
        return manifest
    except Exception:
        if reloaded is not None:
            del reloaded
        if model is not None:
            del model
        release_mlx_memory()
        # This directory was created by this invocation and is never an input
        # model; cleanup prevents an incomplete artifact from being mistaken
        # for a valid one on the next run.
        if temporary.exists():
            import shutil

            shutil.rmtree(temporary)
        raise


def main() -> int:
    args = parse_args()
    source = args.source.expanduser().resolve()
    output_root = (
        args.output_root.expanduser().resolve()
        if args.output_root is not None
        else source.parent
    )
    if not source.is_dir():
        raise FileNotFoundError(f"source model directory does not exist: {source}")
    if not (source / "config.json").is_file():
        raise FileNotFoundError(f"source config.json does not exist: {source / 'config.json'}")
    if not (source / "weights.safetensors").is_file():
        raise FileNotFoundError(
            f"source weights.safetensors does not exist: {source / 'weights.safetensors'}"
        )

    source_weights = source / "weights.safetensors"
    source_config = source / "config.json"
    source_info = {
        "path": str(source),
        "weights_file_bytes": source_weights.stat().st_size,
        "weights_sha256": sha256_file(source_weights),
        "config_file_bytes": source_config.stat().st_size,
        "config_sha256": sha256_file(source_config),
    }
    command = shlex.join([sys.executable, *sys.argv])
    print(f"Source weights: {source_info['weights_file_bytes']:,} bytes", flush=True)
    print(f"Source SHA-256: {source_info['weights_sha256']}", flush=True)

    manifests: list[dict[str, object]] = []
    failures: list[str] = []
    for variant in VARIANTS:
        try:
            manifests.append(
                build_variant(
                    variant,
                    source,
                    output_root,
                    source_info,
                    command,
                    run_smoke_test=not args.no_smoke_test,
                    replace_generated=args.replace_generated,
                )
            )
        except Exception as exc:
            failure = f"{variant['name']}: {type(exc).__name__}: {exc}"
            failures.append(failure)
            print(f"ERROR {failure}", file=sys.stderr, flush=True)

    print("\nArtifact summary:", flush=True)
    for manifest in manifests:
        files = manifest["files"]
        print(
            f"- {manifest['artifact']}: "
            f"{files['weights_file_bytes']:,} bytes, "
            f"sha256={files['weights_sha256']}, "
            f"quantized_modules={manifest['selected_module_count']}",
            flush=True,
        )
    if failures:
        print("Failures:", file=sys.stderr, flush=True)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
