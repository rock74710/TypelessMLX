#!/usr/bin/env python3
"""
TypelessMLX - Persistent MLX Whisper transcription server.
Communicates via newline-delimited JSON over stdin/stdout (JSON-RPC style).
"""
import argparse
import gc
import sys
import json
import os
import platform
import re
from pathlib import Path
import traceback

from model_validation import (
    MODEL_MANIFEST,
    ModelValidationError,
    cache_snapshot_path,
    check_ready_marker,
    find_ready_remote_path,
    load_model_manifest,
    model_cache_size,
    read_conversion_provenance,
    read_quantization_provenance,
    ready_marker_data,
    remote_model_spec,
    validate_and_mark,
)

_HESITATION_RE = re.compile(
    r'(?<![^\s，。！？、])(?:呃+|嗯+|啊+|哦+|喔+|哎+)(?=[,，。！？、\s]|$)',
    re.UNICODE
)


def strip_hesitations(text: str) -> str:
    text = _HESITATION_RE.sub('', text)
    text = re.sub(r'[，、]\s*[，、]', '，', text)   # collapse duplicate punctuation
    text = re.sub(r'^\s*[，。、！？]\s*', '', text)   # strip leading punctuation
    return text.strip()

_TRANSCRIPTION_PROMPT = "請以繁體中文忠實輸出語音辨識原文，保留語氣詞，不改寫或補上標點。"


def ensure_trailing_punctuation(text: str) -> str:
    """若文字結尾沒有標點符號，補上句號。"""
    if text and text[-1] not in '。？！…」』':
        return text + '。'
    return text

# Prefer the validated local Breeze 8-bit artifact.  Keep the original FP16
# directory and the existing HF repo as compatibility fallbacks so an
# installation that predates the quantized artifact keeps working.
BREEZE_8BIT_MODEL = os.path.expanduser(
    "~/.local/share/typelessmlx/models/breeze-asr-25-mlx-8bit"
)
BREEZE_FP16_MODEL = os.path.expanduser(
    "~/.local/share/typelessmlx/models/breeze-asr-25-mlx"
)
BREEZE_REMOTE_MODEL = "schsu/breeze-asr-25-mlx"
DEFAULT_MODEL = BREEZE_8BIT_MODEL
FALLBACK_MODEL = BREEZE_REMOTE_MODEL


def _is_usable_model(path: str) -> bool:
    expanded = Path(path).expanduser()
    if expanded.resolve() == Path(BREEZE_8BIT_MODEL).expanduser().resolve():
        return _local_breeze_ready(str(expanded), "breeze-8bit")
    if expanded.resolve() == Path(BREEZE_FP16_MODEL).expanduser().resolve():
        return _local_breeze_ready(str(expanded), "breeze-fp16")
    for model_id, spec in _MODEL_MANIFEST["models"].items():
        cached = cache_snapshot_path(spec["repo_id"], spec["revision"])
        if expanded.resolve() == cached.resolve():
            return _remote_ready(model_id, expanded)
    return False


def running_on_apple_silicon() -> bool:
    machine = platform.machine() or ""
    return sys.platform == "darwin" and machine.lower().startswith("arm")


def send(data: dict):
    print(json.dumps(data, ensure_ascii=False), flush=True)


_MODEL_MANIFEST = load_model_manifest()
_BREEZE_SOURCE = _MODEL_MANIFEST["conversion_sources"]["breeze-asr-25-canonical"]
_BREEZE_REMOTE_SPEC = _MODEL_MANIFEST["models"]["breeze-asr-25"]


def _breeze_local_revision(kind: str) -> str:
    source_revision = (
        _BREEZE_REMOTE_SPEC["revision"] if kind == "breeze-8bit" else _BREEZE_SOURCE["revision"]
    )
    return f"local:{kind}:{source_revision}"


def _local_marker_files(kind: str) -> dict[str, dict]:
    manifest_file = "quantization_manifest.json" if kind == "breeze-8bit" else "conversion_manifest.json"
    return {
        "config.json": {},
        "weights.safetensors": {},
        manifest_file: {},
    }


def _local_breeze_ready(path: str, kind: str) -> bool:
    return check_ready_marker(
        model_id="breeze-asr-25",
        model_path=path,
        revision=_breeze_local_revision(kind),
        files=_local_marker_files(kind),
    )[0]


def _remote_ready(model_id: str, path: Path) -> bool:
    spec = remote_model_spec(model_id)
    return check_ready_marker(
        model_id=model_id,
        model_path=path,
        revision=spec["revision"],
        files=spec["required_files"],
    )[0]


def _load_whisper(path: Path) -> bool:
    import mlx.core as mx
    from mlx_whisper.load_models import load_model

    dtype = mx.float16 if running_on_apple_silicon() else mx.float32
    model = load_model(str(path), dtype=dtype)
    del model
    gc.collect()
    try:
        mx.clear_cache()
    except AttributeError:
        pass
    return True


def _load_qwen3(path: Path) -> bool:
    from mlx_audio.stt.utils import load_model

    model = load_model(str(path))
    del model
    gc.collect()
    return True


def _loader_for(model_type: str):
    return _load_qwen3 if model_type == "qwen3" else _load_whisper


def _prepare_remote_model(model_id: str) -> dict:
    spec = remote_model_spec(model_id)
    path = find_ready_remote_path(model_id)
    if path is None:
        from huggingface_hub import snapshot_download

        sys.stderr.write(
            f"[TypelessMLX] Downloading pinned model {spec['repo_id']}@{spec['revision']}\n"
        )
        sys.stderr.flush()
        downloaded = snapshot_download(
            repo_id=spec["repo_id"],
            revision=spec["revision"],
            allow_patterns=list(spec["required_files"].keys()),
        )
        path = Path(downloaded).expanduser().resolve()
    if path.name != spec["revision"]:
        raise ModelValidationError(
            f"Hugging Face returned revision {path.name}; expected {spec['revision']}"
        )
    try:
        _validate_remote_path(model_id, path, spec)
    except ModelValidationError as exc:
        integrity_failure = str(exc).startswith(
            ("Required file is missing:", "Required path is not a file:", "Wrong size for", "Trusted ")
        )
        if not integrity_failure:
            raise
        from huggingface_hub import snapshot_download

        sys.stderr.write(f"[TypelessMLX] Repairing invalid pinned snapshot: {exc}\n")
        sys.stderr.flush()
        repaired = snapshot_download(
            repo_id=spec["repo_id"],
            revision=spec["revision"],
            allow_patterns=list(spec["required_files"].keys()),
            force_download=True,
        )
        path = Path(repaired).expanduser().resolve()
        _validate_remote_path(model_id, path, spec)
    return {
        "status": "ready",
        "model_id": model_id,
        "path": str(path),
        "source": "remote",
        "revision": spec["revision"],
        "size": model_cache_size(path),
    }


def _validate_remote_path(model_id: str, path: Path, spec: dict) -> None:
    validate_and_mark(
        model_id=model_id,
        model_path=path,
        revision=spec["revision"],
        files=spec["required_files"],
        loader=_loader_for(spec["model_type"]),
        loader_name=(
            "mlx_audio.stt.utils.load_model"
            if spec["model_type"] == "qwen3"
            else "mlx_whisper.load_models.load_model"
        ),
        provenance={
            "type": "huggingface-remote",
            "repo_id": spec["repo_id"],
            "revision": spec["revision"],
        },
    )


def _prepare_local_breeze_fp16(path: Path) -> dict:
    kind = "breeze-fp16"
    revision = _breeze_local_revision(kind)
    if _local_breeze_ready(str(path), kind):
        return {
            "status": "ready",
            "model_id": "breeze-asr-25",
            "path": str(path),
            "source": "local-fp16",
            "revision": revision,
        }
    files, provenance = read_conversion_provenance(path, _BREEZE_SOURCE)
    validate_and_mark(
        model_id="breeze-asr-25",
        model_path=path,
        revision=revision,
        files=files,
        loader=_load_whisper,
        loader_name="mlx_whisper.load_models.load_model",
        provenance=provenance,
    )
    return {
        "status": "ready",
        "model_id": "breeze-asr-25",
        "path": str(path),
        "source": "local-fp16",
        "revision": revision,
        "size": model_cache_size(path),
    }


def _prepare_local_breeze_8bit(path: Path) -> dict:
    kind = "breeze-8bit"
    revision = _breeze_local_revision(kind)
    source_required_files = _BREEZE_REMOTE_SPEC["required_files"]
    config_spec = source_required_files["config.json"]
    weights_spec = source_required_files["weights.safetensors"]
    if not config_spec.get("content_sha256"):
        raise ModelValidationError("Pinned Breeze source config has no content SHA-256")
    source_provenance = {
        "type": "huggingface-remote",
        "source": {
            "repo_id": _BREEZE_REMOTE_SPEC["repo_id"],
            "revision": _BREEZE_REMOTE_SPEC["revision"],
        },
        "outputs": {
            "config.json": {
                "size": config_spec["size"],
                "sha256": config_spec["content_sha256"],
            },
            "weights.safetensors": {
                "size": weights_spec["size"],
                "sha256": weights_spec["digest"],
            },
        },
    }
    files, provenance = read_quantization_provenance(path, source_provenance)
    validate_and_mark(
        model_id="breeze-asr-25",
        model_path=path,
        revision=revision,
        files=files,
        loader=_load_whisper,
        loader_name="mlx_whisper.load_models.load_model",
        provenance=provenance,
    )
    return {
        "status": "ready",
        "model_id": "breeze-asr-25",
        "path": str(path),
        "source": "local-8bit",
        "revision": revision,
        "size": model_cache_size(path),
    }


def prepare_model(model_id: str) -> dict:
    """Download, verify, and load a selected model before recording starts."""
    if model_id == "macos-speech":
        return {"status": "ready", "model_id": model_id, "path": "", "source": "native"}
    if model_id == "breeze-asr-25":
        local_candidates = (
            (Path(BREEZE_8BIT_MODEL).expanduser(), _prepare_local_breeze_8bit),
            (Path(BREEZE_FP16_MODEL).expanduser(), _prepare_local_breeze_fp16),
        )
        errors: list[str] = []
        for path, prepare_local in local_candidates:
            if not path.is_dir():
                continue
            try:
                if _local_breeze_ready(
                    str(path), "breeze-8bit" if "8bit" in path.name else "breeze-fp16"
                ):
                    return {
                        "status": "ready",
                        "model_id": model_id,
                        "path": str(path),
                        "source": "local-8bit" if "8bit" in path.name else "local-fp16",
                        "revision": _breeze_local_revision(
                            "breeze-8bit" if "8bit" in path.name else "breeze-fp16"
                        ),
                        "size": model_cache_size(path),
                    }
                return_value = prepare_local(path)
                return return_value
            except Exception as exc:
                message = f"{path.name}: {type(exc).__name__}: {exc}"
                errors.append(message)
                sys.stderr.write(f"[TypelessMLX] {message}; trying next Breeze source\n")
                sys.stderr.flush()
        try:
            return _prepare_remote_model(model_id)
        except Exception as exc:
            details = "; ".join(errors)
            if details:
                raise RuntimeError(f"Remote fallback failed ({exc}); local checks: {details}") from exc
            raise
    return _prepare_remote_model(model_id)


def _candidate_paths(model_id: str) -> list[tuple[Path, str, dict[str, dict]]]:
    if model_id == "breeze-asr-25":
        candidates = [
            (
                Path(BREEZE_8BIT_MODEL).expanduser(),
                _breeze_local_revision("breeze-8bit"),
                _local_marker_files("breeze-8bit"),
            ),
            (
                Path(BREEZE_FP16_MODEL).expanduser(),
                _breeze_local_revision("breeze-fp16"),
                _local_marker_files("breeze-fp16"),
            ),
        ]
        spec = remote_model_spec(model_id)
        candidates.append(
            (
                cache_snapshot_path(spec["repo_id"], spec["revision"]),
                spec["revision"],
                spec["required_files"],
            )
        )
        return candidates
    spec = remote_model_spec(model_id)
    return [
        (
            cache_snapshot_path(spec["repo_id"], spec["revision"]),
            spec["revision"],
            spec["required_files"],
        )
    ]


def check_model_status(model_id: str) -> dict:
    if model_id == "macos-speech":
        return {"status": "ready", "model_id": model_id, "path": "", "size": 0}
    existing: list[tuple[Path, str, dict[str, dict]]] = []
    for path, revision, files in _candidate_paths(model_id):
        if not path.is_dir():
            continue
        existing.append((path, revision, files))
        ready, _reason = check_ready_marker(
            model_id=model_id,
            model_path=path,
            revision=revision,
            files=files,
        )
        if ready:
            return {
                "status": "ready",
                "model_id": model_id,
                "path": str(path),
                "size": model_cache_size(path),
            }
    if existing:
        path = existing[0][0]
        return {
            "status": "needs_repair",
            "model_id": model_id,
            "path": str(path),
            "size": model_cache_size(path),
            "message": "Model files need integrity and loader validation",
        }
    return {"status": "not_installed", "model_id": model_id, "path": "", "size": 0}


_qwen3_model = None
_qwen3_model_path = None


def transcribe_qwen3(audio_path: str, model_path: str, language: str | None,
                     remove_fillers: bool = False) -> str:
    global _qwen3_model, _qwen3_model_path
    from mlx_audio.stt.utils import load_model
    from mlx_audio.stt.generate import generate_transcription
    if _qwen3_model is None or _qwen3_model_path != model_path:
        sys.stderr.write(f"[TypelessMLX] Loading Qwen3-ASR model: {os.path.basename(model_path)}\n")
        sys.stderr.flush()
        _qwen3_model = load_model(model_path)
        _qwen3_model_path = model_path
    import tempfile
    tmp_path = os.path.join(tempfile.gettempdir(), f"typelessmlx_qwen3_{os.getpid()}")
    system = "請以繁體中文忠實輸出語音辨識原文，保留語氣詞，不改寫或補上標點。"
    result = generate_transcription(
        model=_qwen3_model,
        audio=audio_path,
        output_path=tmp_path,
        format="txt",
        system_prompt=system,
    )
    try:
        os.remove(tmp_path + ".txt")
    except OSError:
        pass
    text = (result.text if hasattr(result, "text") else str(result)).strip()
    return text


def transcribe(audio_path: str, model_path: str, language: str | None,
               initial_prompt: str | None = None, model_type: str = "whisper",
               remove_fillers: bool = False) -> str:
    model_path = require_ready_model_path(model_path, model_type)
    if model_type == "qwen3":
        return transcribe_qwen3(audio_path, model_path, language, remove_fillers)
    import mlx_whisper
    use_fp16 = model_type == "whisper" and running_on_apple_silicon()
    if use_fp16:
        sys.stderr.write(
            "[TypelessMLX] Apple Silicon detected, using fp16 compute for non-quantized operations\n"
        )
        sys.stderr.flush()
    result = mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=model_path,
        language=language or None,
        initial_prompt=initial_prompt or _TRANSCRIPTION_PROMPT,
        verbose=False,
        fp16=use_fp16,
    )
    text = result.get("text", "").strip()
    return text


def _breeze_ready_path() -> str | None:
    for path, kind in (
        (BREEZE_8BIT_MODEL, "breeze-8bit"),
        (BREEZE_FP16_MODEL, "breeze-fp16"),
    ):
        if _local_breeze_ready(path, kind):
            return path
    remote_path = find_ready_remote_path("breeze-asr-25")
    if remote_path is not None and _remote_ready("breeze-asr-25", remote_path):
        return str(remote_path)
    return None


def resolve_model(requested: str | None) -> str:
    """Resolve only a model that has a current successful readiness marker."""
    requested = requested.strip() if requested else ""
    if requested in {"", "breeze-asr-25", BREEZE_8BIT_MODEL, BREEZE_FP16_MODEL, BREEZE_REMOTE_MODEL}:
        ready_path = _breeze_ready_path()
        if ready_path is not None:
            sys.stderr.write(f"[TypelessMLX] Using ready Breeze artifact: {ready_path}\n")
            sys.stderr.flush()
            return ready_path
        return requested or FALLBACK_MODEL

    for model_id, spec in _MODEL_MANIFEST["models"].items():
        cached = cache_snapshot_path(spec["repo_id"], spec["revision"])
        if requested == spec["repo_id"] or Path(requested).expanduser().resolve() == cached.resolve():
            if cached.is_dir() and _remote_ready(model_id, cached):
                return str(cached)
            return requested
    return requested


def require_ready_model_path(requested: str, model_type: str) -> str:
    """Refuse inference unless the requested path has a valid readiness marker."""
    path = resolve_model(requested)
    expanded = Path(path).expanduser()
    if model_type == "qwen3":
        model_id = "qwen3-asr-0.6b"
        spec = remote_model_spec(model_id)
        cached = cache_snapshot_path(spec["repo_id"], spec["revision"])
        candidate = cached if path == spec["repo_id"] else expanded
        if candidate.is_dir() and _remote_ready(model_id, candidate):
            return str(candidate)
        raise ModelValidationError("Qwen3-ASR is not ready; prepare the model before transcription")

    local_candidates = (
        (Path(BREEZE_8BIT_MODEL).expanduser(), "breeze-8bit"),
        (Path(BREEZE_FP16_MODEL).expanduser(), "breeze-fp16"),
    )
    for candidate, kind in local_candidates:
        if expanded.resolve() == candidate.resolve() and _local_breeze_ready(str(candidate), kind):
            return str(candidate)

    for model_id, spec in _MODEL_MANIFEST["models"].items():
        cached = cache_snapshot_path(spec["repo_id"], spec["revision"])
        requested_matches = path == spec["repo_id"] or expanded.resolve() == cached.resolve()
        if requested_matches and cached.is_dir() and _remote_ready(model_id, cached):
            return str(cached)
    raise ModelValidationError("Selected model is not ready; prepare it before transcription")


def _run_readiness_command(args: argparse.Namespace) -> int:
    try:
        if args.check_model:
            send(check_model_status(args.check_model))
            return 0
        result = prepare_model(args.prepare_model)
        send(result)
        return 0
    except Exception as exc:
        send(
            {
                "status": "error",
                "model_id": args.prepare_model or args.check_model,
                "message": f"{type(exc).__name__}: {exc}",
            }
        )
        return 1


def main(argv: list[str] | None = None):
    parser = argparse.ArgumentParser(add_help=False)
    command = parser.add_mutually_exclusive_group()
    command.add_argument("--check-model")
    command.add_argument("--prepare-model")
    args, _unknown = parser.parse_known_args(argv)
    if args.check_model or args.prepare_model:
        return _run_readiness_command(args)

    # Signal Swift that we're ready
    send({"status": "ready"})
    sys.stderr.write("[TypelessMLX] Python backend ready\n")
    sys.stderr.write(f"[TypelessMLX] Whisper compute dtype: {'fp16' if running_on_apple_silicon() else 'fp32'} (quantized weight metadata is model-specific, arch: {platform.machine()})\n")
    sys.stderr.flush()

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            sys.stderr.write(f"[TypelessMLX] JSON parse error: {e}\n")
            sys.stderr.flush()
            continue

        req_id = req.get("id", "")
        action = req.get("action", "")

        try:
            if action == "ping":
                send({"id": req_id, "status": "pong"})

            elif action == "transcribe":
                audio_path = req.get("audio_path", "")
                if not audio_path or not os.path.exists(audio_path):
                    send({"id": req_id, "text": "", "error": f"Audio file not found: {audio_path}"})
                    continue

                model = resolve_model(req.get("model"))
                language = req.get("language")
                initial_prompt = req.get("initial_prompt")
                model_type = req.get("model_type", "whisper")
                remove_fillers = req.get("remove_fillers", False)

                sys.stderr.write(f"[TypelessMLX] Transcribing with model: {os.path.basename(model)}, type: {model_type}, lang: {language or 'auto'}, remove_fillers: {remove_fillers}\n")
                sys.stderr.flush()

                text = transcribe(audio_path, model, language, initial_prompt, model_type, remove_fillers)
                send({"id": req_id, "text": text, "error": None})

            else:
                send({"id": req_id, "error": f"Unknown action: {action}"})

        except Exception as e:
            error_msg = f"{type(e).__name__}: {e}"
            sys.stderr.write(f"[TypelessMLX] Error handling '{action}': {traceback.format_exc()}\n")
            sys.stderr.flush()
            send({"id": req_id, "text": "", "error": error_msg})


if __name__ == "__main__":
    sys.exit(main())
