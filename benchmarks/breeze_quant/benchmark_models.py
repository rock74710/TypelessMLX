#!/usr/bin/env python3
"""Sequential, reproducible mlx-whisper model benchmark.

The driver starts one fresh worker subprocess for every model/config pair.  A
worker loads exactly one model, measures cold load and the first inference,
then performs one unmeasured warm-up and at least three measured hot runs for
each corpus item.  Models are never run concurrently.

The default corpus is generated locally by macOS ``say`` and is explicitly
synthetic; it is useful for timing/regression checks only, not accuracy claims.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import math
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import wave
from datetime import datetime, timezone
from pathlib import Path
from statistics import median
from typing import Any


SCRIPT_PATH = Path(__file__).resolve()
SCRIPT_DIR = SCRIPT_PATH.parent
DEFAULT_MANIFEST = SCRIPT_DIR / "corpus_manifest.json"
DEFAULT_MODEL = Path(
    os.path.expanduser("~/.local/share/typelessmlx/models/breeze-asr-25-mlx")
)
DEFAULT_AUDIO_DIR = Path(tempfile.gettempdir()) / "typelessmlx-breeze-quant-corpus-v1"
DEFAULT_HOT_RUNS = 3

# Keep this prompt byte-for-byte identical for every model/config.  It is
# intentionally bilingual and includes vocabulary found in the synthetic set.
INITIAL_PROMPT = (
    "這是台灣中文與 English 混合語音辨識，請保留 API、MLX、Whisper、"
    "GitHub、URL、數字與英文大小寫。"
)

DECODING_CONFIGS: dict[str, dict[str, Any]] = {
    "zh_fp16_greedy": {
        "language": "zh",
        "temperature": 0.0,
        "fp16": True,
        "verbose": None,
        "without_timestamps": True,
        "initial_prompt": INITIAL_PROMPT,
        "task": "transcribe",
        "condition_on_previous_text": True,
    }
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def sha256_file(path: Path, chunk_size: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def sha256_json(value: Any) -> str:
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object in {path}")
    return value


def normalize_external_manifest(raw: dict[str, Any], path: Path) -> dict[str, Any]:
    """Adapt an external per-utterance manifest without discarding provenance."""

    items = raw.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("External manifest needs a non-empty items list")
    dataset = raw.get("dataset", {})
    selection = raw.get("selection", {})
    source = {
        "type": "external_real_audio",
        "synthetic": False,
        "accuracy_evidence": "directional_subset",
        "description": raw.get("purpose"),
        "manifest_version": raw.get("manifest_version"),
        "created_at": raw.get("created_at"),
        "selection": selection,
        "dataset": dataset,
        "license": dataset.get("license") if isinstance(dataset, dict) else None,
        "license_url": dataset.get("license_url") if isinstance(dataset, dict) else None,
        "reference_field": "reference_transcript",
    }
    samples: list[dict[str, Any]] = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError("Every external manifest item must be an object")
        filename = item.get("audio_file")
        reference = item.get("reference_transcript")
        if not isinstance(filename, str) or not filename:
            raise ValueError(f"External item {index} has no audio_file")
        if not isinstance(reference, str) or not reference.strip():
            raise ValueError(f"External item {index} has no reference_transcript")
        audio_path = Path(filename).expanduser()
        if not audio_path.is_absolute():
            audio_path = path.parent / audio_path
        sample_id = item.get("dataset_example_id") or item.get("id") or f"item-{index:05d}"
        samples.append(
            {
                "id": str(sample_id),
                "category": "external_mixed",
                "text": reference,
                "reference_transcript": reference,
                "audio_filename": filename,
                "audio_path": str(audio_path.resolve()),
                "language": item.get("language"),
                "start_language": item.get("start_language"),
                "speaker_id": item.get("speaker_id"),
                "session_id": item.get("session_id"),
                "source_item": item,
            }
        )
    manifest = dict(raw)
    manifest["source"] = source
    manifest["samples"] = samples
    return manifest


def read_manifest(path: Path) -> dict[str, Any]:
    manifest = load_json(path)
    if "samples" not in manifest and "items" in manifest:
        manifest = normalize_external_manifest(manifest, path)
    samples = manifest.get("samples")
    if not isinstance(samples, list) or not samples:
        raise ValueError(f"Manifest has no samples: {path}")
    ids: set[str] = set()
    for sample in samples:
        if not isinstance(sample, dict):
            raise ValueError("Each manifest sample must be an object")
        sample_id = sample.get("id")
        text = sample.get("text")
        filename = sample.get("audio_filename")
        if not isinstance(sample_id, str) or not sample_id:
            raise ValueError("Every sample needs a non-empty string id")
        if sample_id in ids:
            raise ValueError(f"Duplicate sample id: {sample_id}")
        if not isinstance(text, str) or not text.strip():
            raise ValueError(f"Sample {sample_id} needs non-empty text")
        if not isinstance(filename, str) or not filename:
            raise ValueError(f"Sample {sample_id} has an empty audio_filename")
        filename_path = Path(filename).expanduser()
        if not filename_path.is_absolute() and ".." in filename_path.parts:
            raise ValueError(f"Sample {sample_id} has an unsafe audio_filename")
        ids.add(sample_id)
    return manifest


def samples_from_manifest(
    manifest: dict[str, Any], selected_ids: list[str] | None
) -> list[dict[str, Any]]:
    samples = manifest["samples"]
    by_id = {sample["id"]: sample for sample in samples}
    if not selected_ids:
        return list(samples)
    missing = [sample_id for sample_id in selected_ids if sample_id not in by_id]
    if missing:
        raise ValueError(
            f"Unknown sample id(s): {', '.join(missing)}; available: {', '.join(by_id)}"
        )
    return [by_id[sample_id] for sample_id in selected_ids]


def run_checked(command: list[str]) -> None:
    try:
        subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError as exc:
        raise RuntimeError(f"Required executable is not available: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or b"").decode(errors="replace").strip()
        raise RuntimeError(
            f"Command failed ({exc.returncode}): {shlex.join(command)}\n{stderr}"
        ) from exc


def ensure_synthetic_corpus(
    manifest: dict[str, Any], audio_dir: Path, force: bool = False
) -> list[dict[str, Any]]:
    """Generate the manifest's macOS say corpus and return audio metadata.

    Generation is intentionally explicit.  No network or public speech data
    is fetched; the manifest source field is the authority for this corpus.
    """

    source = manifest.get("source", {})
    if source.get("type") != "synthetic_macos_say":
        raise ValueError(
            "This harness only generates manifests marked source.type=synthetic_macos_say"
        )
    say = source.get("generator", "/usr/bin/say")
    afconvert = source.get("converter", "/usr/bin/afconvert")
    voice = source.get("voice", "Meijia")
    rate = str(source.get("rate_words_per_minute", 165))
    if not Path(say).exists() or not Path(afconvert).exists():
        raise RuntimeError(
            "Synthetic corpus requires macOS /usr/bin/say and /usr/bin/afconvert"
        )

    audio_dir.mkdir(parents=True, exist_ok=True)
    metadata: list[dict[str, Any]] = []
    for sample in manifest["samples"]:
        wav_path = audio_dir / sample["audio_filename"]
        if force or not wav_path.exists():
            aiff_path = wav_path.with_suffix(".aiff")
            # Pass text as an argv item, never through a shell.  The source
            # manifest remains the reproducibility record for the utterance.
            run_checked(
                [
                    say,
                    "-v",
                    voice,
                    "-r",
                    rate,
                    "-o",
                    str(aiff_path),
                    sample["text"],
                ]
            )
            try:
                run_checked(
                    [
                        afconvert,
                        "-f",
                        "WAVE",
                        "-d",
                        "LEI16@16000",
                        "-c",
                        "1",
                        str(aiff_path),
                        str(wav_path),
                    ]
                )
            finally:
                try:
                    aiff_path.unlink()
                except FileNotFoundError:
                    pass
        if not wav_path.is_file():
            raise RuntimeError(f"Audio generation did not produce {wav_path}")
        metadata.append(audio_metadata(wav_path, sample))
    return metadata


def sample_audio_path(
    manifest_path: Path, audio_dir: Path, sample: dict[str, Any]
) -> Path:
    explicit_path = sample.get("audio_path")
    if explicit_path:
        return Path(str(explicit_path)).expanduser().resolve()
    return (audio_dir / sample["audio_filename"]).resolve()


def external_audio_corpus(
    manifest_path: Path, audio_dir: Path, manifest: dict[str, Any]
) -> list[dict[str, Any]]:
    """Validate and describe external audio; never generate or modify it."""

    metadata: list[dict[str, Any]] = []
    for sample in manifest["samples"]:
        audio_path = sample_audio_path(manifest_path, audio_dir, sample)
        if not audio_path.is_file():
            raise FileNotFoundError(f"External audio file does not exist: {audio_path}")
        info = audio_metadata(audio_path, sample)
        source_item = sample.get("source_item", {})
        expected_hash = source_item.get("audio_sha256")
        if expected_hash:
            info["manifest_audio_sha256"] = expected_hash
            info["manifest_audio_sha256_match"] = info["sha256"] == expected_hash
        if source_item.get("duration_seconds") is not None:
            info["manifest_duration_s"] = source_item["duration_seconds"]
        metadata.append(info)
    return metadata


def prepare_corpus(
    manifest_path: Path,
    audio_dir: Path,
    manifest: dict[str, Any],
    force: bool = False,
) -> list[dict[str, Any]]:
    source_type = manifest.get("source", {}).get("type")
    if source_type == "synthetic_macos_say":
        return ensure_synthetic_corpus(manifest, audio_dir, force=force)
    if source_type == "external_real_audio":
        if force:
            raise ValueError("--force-corpus cannot modify an external audio corpus")
        return external_audio_corpus(manifest_path, audio_dir, manifest)
    raise ValueError(f"Unsupported manifest source.type: {source_type!r}")


def audio_metadata(path: Path, sample: dict[str, Any] | None = None) -> dict[str, Any]:
    with wave.open(str(path), "rb") as stream:
        channels = stream.getnchannels()
        sample_width = stream.getsampwidth()
        sample_rate = stream.getframerate()
        frames = stream.getnframes()
    duration = frames / sample_rate if sample_rate else 0.0
    result: dict[str, Any] = {
        "path": str(path.resolve()),
        "sha256": sha256_file(path),
        "size_bytes": path.stat().st_size,
        "sample_rate_hz": sample_rate,
        "channels": channels,
        "sample_width_bytes": sample_width,
        "frames": frames,
        "duration_s": duration,
    }
    if sample is not None:
        result["sample_id"] = sample["id"]
        result["expected_text"] = sample["text"]
        result["category"] = sample.get("category")
    return result


def model_metadata(model_path: Path) -> dict[str, Any]:
    model_path = model_path.resolve()
    if not model_path.is_dir():
        raise FileNotFoundError(f"Model directory does not exist: {model_path}")
    config_path = model_path / "config.json"
    if not config_path.is_file():
        raise FileNotFoundError(f"Missing model config: {config_path}")
    weight_candidates = [model_path / "weights.safetensors", model_path / "weights.npz"]
    weight_path = next((path for path in weight_candidates if path.is_file()), None)
    if weight_path is None:
        raise FileNotFoundError(f"Missing model weights in {model_path}")

    files: dict[str, dict[str, Any]] = {}
    tree_digest = hashlib.sha256()
    for path in sorted(path for path in model_path.rglob("*") if path.is_file()):
        relative = path.relative_to(model_path).as_posix()
        digest = sha256_file(path)
        files[relative] = {"sha256": digest, "size_bytes": path.stat().st_size}
        tree_digest.update(relative.encode("utf-8"))
        tree_digest.update(b"\0")
        tree_digest.update(digest.encode("ascii"))
        tree_digest.update(b"\0")

    config_bytes = config_path.read_bytes()
    with config_path.open("r", encoding="utf-8") as stream:
        config = json.load(stream)
    return {
        "path": str(model_path),
        "config_path": str(config_path),
        "weights_path": str(weight_path),
        "config": config,
        "config_sha256": hashlib.sha256(config_bytes).hexdigest(),
        "weights_sha256": files[weight_path.relative_to(model_path).as_posix()]["sha256"],
        "weights_size_bytes": weight_path.stat().st_size,
        "files": files,
        "model_tree_sha256": tree_digest.hexdigest(),
    }


def package_version(distribution: str) -> str | None:
    try:
        from importlib.metadata import version

        return version(distribution)
    except Exception:
        return None


def runtime_metadata() -> dict[str, Any]:
    return {
        "python": sys.version,
        "python_executable": sys.executable,
        "platform": platform.platform(),
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "mlx_version": package_version("mlx"),
        "mlx_whisper_version": package_version("mlx-whisper"),
        "numpy_version": package_version("numpy"),
        "macos_version": platform.mac_ver()[0] or None,
    }


def config_for(name: str) -> dict[str, Any]:
    try:
        return dict(DECODING_CONFIGS[name])
    except KeyError as exc:
        raise ValueError(
            f"Unknown config {name}; available: {', '.join(DECODING_CONFIGS)}"
        ) from exc


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * p
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return ordered[lower]
    fraction = rank - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


_CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
_LATIN_WORD_RE = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)?")
_NUMBER_RE = re.compile(r"[0-9]+(?:[.,][0-9]+)*")


def mixed_tokens(text: str, case_sensitive: bool = False) -> list[str]:
    """Tokenize CJK as characters and Latin/number runs as word/number tokens.

    NFKC normalization is applied first. Punctuation and whitespace are
    ignored. Latin runs are extracted even when attached to CJK (common in
    code-switch transcripts); case-insensitive scoring casefolds only those
    Latin/number tokens. This is the documented mixed error unit.
    """

    normalized = unicodedata.normalize("NFKC", text)
    tokens: list[str] = []
    cursor = 0
    while cursor < len(normalized):
        cjk_match = _CJK_RE.match(normalized, cursor)
        if cjk_match:
            tokens.append(cjk_match.group(0))
            cursor = cjk_match.end()
            continue
        latin_match = _LATIN_WORD_RE.match(normalized, cursor)
        if latin_match:
            token = latin_match.group(0)
            tokens.append(token if case_sensitive else token.casefold())
            cursor = latin_match.end()
            continue
        number_match = _NUMBER_RE.match(normalized, cursor)
        if number_match:
            tokens.append(number_match.group(0))
            cursor = number_match.end()
            continue
        cursor += 1
    return tokens


def sequence_edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for ref_index, ref_token in enumerate(reference, start=1):
        current = [ref_index]
        for hyp_index, hyp_token in enumerate(hypothesis, start=1):
            substitution = previous[hyp_index - 1] + (ref_token != hyp_token)
            insertion = current[hyp_index - 1] + 1
            deletion = previous[hyp_index] + 1
            current.append(min(substitution, insertion, deletion))
        previous = current
    return previous[-1]


def punctuation_signature(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text)
    return [
        char
        for char in normalized
        if unicodedata.category(char).startswith(("P", "S"))
    ]


def score_mixed_transcript(reference: str, hypothesis: str) -> dict[str, Any]:
    reference_tokens = mixed_tokens(reference, case_sensitive=False)
    hypothesis_tokens = mixed_tokens(hypothesis, case_sensitive=False)
    case_reference_tokens = mixed_tokens(reference, case_sensitive=True)
    case_hypothesis_tokens = mixed_tokens(hypothesis, case_sensitive=True)
    insensitive_distance = sequence_edit_distance(reference_tokens, hypothesis_tokens)
    sensitive_distance = sequence_edit_distance(
        case_reference_tokens, case_hypothesis_tokens
    )
    reference_punctuation = punctuation_signature(reference)
    hypothesis_punctuation = punctuation_signature(hypothesis)
    return {
        "normalization": {
            "unicode": "NFKC",
            "cjk": "one token per CJK ideograph",
            "latin": "contiguous ASCII Latin word runs; apostrophes retained",
            "numbers": "contiguous numeric runs with decimal/comma separators",
            "whitespace": "ignored after mixed token extraction",
            "punctuation": "excluded from mixed token error; scored separately",
            "main_case": "ASCII Latin tokens casefolded",
        },
        "reference_token_count": len(reference_tokens),
        "hypothesis_token_count": len(hypothesis_tokens),
        "edit_distance": insensitive_distance,
        "error_rate": insensitive_distance / max(1, len(reference_tokens)),
        "case_sensitive_edit_distance": sensitive_distance,
        "case_sensitive_error_rate": sensitive_distance
        / max(1, len(case_reference_tokens)),
        "reference_punctuation": "".join(reference_punctuation),
        "hypothesis_punctuation": "".join(hypothesis_punctuation),
        "punctuation_edit_distance": sequence_edit_distance(
            reference_punctuation, hypothesis_punctuation
        ),
        "punctuation_exact_match": reference_punctuation == hypothesis_punctuation,
    }


def mx_memory_snapshot(mx: Any) -> dict[str, int]:
    # synchronize ensures lazy MLX work has completed before timing/memory is
    # sampled.  These APIs are present in MLX 0.31.1.
    mx.synchronize()
    return {
        "mx_peak_memory_bytes": int(mx.get_peak_memory()),
        "mx_active_memory_bytes": int(mx.get_active_memory()),
        "mx_cache_memory_bytes": int(mx.get_cache_memory()),
    }


def transcribe_once(
    mlx_whisper: Any, audio_path: str, model_path: str, config: dict[str, Any]
) -> str:
    result = mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo=model_path,
        language=config["language"],
        temperature=config["temperature"],
        fp16=config["fp16"],
        verbose=config["verbose"],
        without_timestamps=config["without_timestamps"],
        initial_prompt=config["initial_prompt"],
        task=config["task"],
        condition_on_previous_text=config["condition_on_previous_text"],
    )
    return str(result.get("text", "")).strip()


def timed_inference(
    mx: Any,
    mlx_whisper: Any,
    audio_path: str,
    model_path: str,
    config: dict[str, Any],
    duration_s: float,
    reference_transcript: str | None = None,
) -> dict[str, Any]:
    mx.reset_peak_memory()
    started = time.perf_counter()
    text = transcribe_once(mlx_whisper, audio_path, model_path, config)
    elapsed = time.perf_counter() - started
    memory = mx_memory_snapshot(mx)
    result = {
        "elapsed_s": elapsed,
        "audio_duration_s": duration_s,
        "rtf": elapsed / duration_s if duration_s > 0 else None,
        "transcript": text,
        "blank_output": not bool(text.strip()),
        **memory,
    }
    if reference_transcript:
        result["mixed_error"] = score_mixed_transcript(reference_transcript, text)
    return result


def timed_model_load(mx: Any, load_model: Any, model_path: str, fp16: bool) -> tuple[Any, dict[str, Any]]:
    mx.reset_peak_memory()
    started = time.perf_counter()
    dtype = mx.float16 if fp16 else mx.float32
    model = load_model(model_path, dtype=dtype)
    elapsed = time.perf_counter() - started
    memory = mx_memory_snapshot(mx)
    return model, {"elapsed_s": elapsed, **memory}


def worker_main(args: argparse.Namespace) -> int:
    # Imports happen only inside a worker.  The driver therefore cannot reuse
    # a model object accidentally between model/config subprocesses.
    manifest_path = Path(args.manifest).resolve()
    manifest = read_manifest(manifest_path)
    selected = samples_from_manifest(manifest, args.sample_id or None)
    config_name = (
        args.config_name[0]
        if isinstance(args.config_name, list)
        else args.config_name
    )
    if not config_name:
        raise ValueError("--worker requires --config-name")
    config = config_for(config_name)
    model_path = Path(args.model_path).resolve()
    model_info = model_metadata(model_path)
    audio_info = {
        sample["id"]: audio_metadata(
            sample_audio_path(manifest_path, Path(args.audio_dir), sample), sample
        )
        for sample in selected
    }
    for sample_id, info in audio_info.items():
        if info["duration_s"] <= 0:
            raise ValueError(f"Sample {sample_id} has no audio duration")

    import mlx.core as mx
    import mlx_whisper
    load_models = importlib.import_module("mlx_whisper.load_models")
    transcribe_module = importlib.import_module("mlx_whisper.transcribe")

    # Explicitly load once so model load and first inference have separate
    # measurements, then seed mlx-whisper's holder with that exact object.
    loaded_model, cold_load = timed_model_load(
        mx, load_models.load_model, str(model_path), bool(config["fp16"])
    )
    transcribe_module.ModelHolder.model = loaded_model
    transcribe_module.ModelHolder.model_path = str(model_path)

    cold_first_sample = selected[0]
    cold_first_path = str(
        sample_audio_path(manifest_path, Path(args.audio_dir), cold_first_sample)
    )
    cold_first = timed_inference(
        mx,
        mlx_whisper,
        cold_first_path,
        str(model_path),
        config,
        audio_info[cold_first_sample["id"]]["duration_s"],
        cold_first_sample.get("reference_transcript"),
    )

    samples_out: list[dict[str, Any]] = []
    for sample in selected:
        sample_id = sample["id"]
        path = str(sample_audio_path(manifest_path, Path(args.audio_dir), sample))
        duration_s = audio_info[sample_id]["duration_s"]
        reference_transcript = sample.get("reference_transcript")
        # One warm run per sample is intentionally not included in hot stats.
        warmup = timed_inference(
            mx,
            mlx_whisper,
            path,
            str(model_path),
            config,
            duration_s,
            reference_transcript,
        )
        hot_runs = [
            timed_inference(
                mx,
                mlx_whisper,
                path,
                str(model_path),
                config,
                duration_s,
                reference_transcript,
            )
            for _ in range(args.hot_runs)
        ]
        hot_times = [run["elapsed_s"] for run in hot_runs]
        hot_rtfs = [run["rtf"] for run in hot_runs if run["rtf"] is not None]
        blank_count = sum(1 for run in hot_runs if run["blank_output"])
        item: dict[str, Any] = {
            "sample": sample,
            "audio": audio_info[sample_id],
            "warmup": warmup,
            "hot_runs": hot_runs,
            "summary": {
                "hot_run_count": len(hot_runs),
                "hot_elapsed_median_s": median(hot_times),
                "hot_elapsed_p95_s": percentile(hot_times, 0.95),
                "hot_rtf_median": median(hot_rtfs) if hot_rtfs else None,
                "hot_rtf_p95": percentile(hot_rtfs, 0.95),
                "hot_blank_output_count": blank_count,
                "hot_blank_output_rate": blank_count / len(hot_runs),
                "hot_transcripts": [run["transcript"] for run in hot_runs],
            },
        }
        if sample_id == cold_first_sample["id"]:
            item["cold_first_inference"] = cold_first
        samples_out.append(item)

    result = {
        "schema_version": 1,
        "result_type": "mlx_whisper_worker_result",
        "created_at_utc": utc_now(),
        "worker_pid": os.getpid(),
        "model_label": args.model_label,
        "config_name": config_name,
        "config": config,
        "config_sha256": sha256_json(config),
        "model": model_info,
        "runtime": runtime_metadata(),
        "harness_path": str(SCRIPT_PATH),
        "harness_sha256": sha256_file(SCRIPT_PATH),
        "manifest_path": str(manifest_path),
        "manifest_sha256": sha256_file(manifest_path),
        "audio_dir": str(Path(args.audio_dir).resolve()),
        "hot_runs_requested": args.hot_runs,
        "cold": {
            "model_load": cold_load,
            "first_inference_sample_id": cold_first_sample["id"],
            "first_inference": cold_first,
            "load_plus_first_inference_s": cold_load["elapsed_s"]
            + cold_first["elapsed_s"],
        },
        "samples": samples_out,
    }
    encoded = json.dumps(result, ensure_ascii=False, sort_keys=True)
    if args.worker_output:
        Path(args.worker_output).write_text(encoded + "\n", encoding="utf-8")
    else:
        print(encoded)
    return 0


def parse_model_spec(spec: str) -> tuple[str, Path]:
    if "=" in spec:
        label, raw_path = spec.split("=", 1)
        label = label.strip()
        raw_path = raw_path.strip()
        if not label or not raw_path:
            raise ValueError(f"Invalid model spec: {spec!r}; use LABEL=PATH")
    else:
        raw_path = spec
        label = Path(os.path.expanduser(spec)).name or "model"
    return label, Path(os.path.expanduser(raw_path)).resolve()


def print_driver_summary(result_path: Path, result: dict[str, Any]) -> None:
    print(f"result_file={result_path}")
    print(f"corpus_dir={result['corpus']['audio_dir']}")
    for item in result["runs"]:
        cold = item["cold"]
        print(
            f"model={item['model_label']} config={item['config_name']} "
            f"cold_load_s={cold['model_load']['elapsed_s']:.3f} "
            f"cold_first_s={cold['first_inference']['elapsed_s']:.3f}"
        )
        for sample in item["samples"]:
            summary = sample["summary"]
            print(
                f"  sample={sample['sample']['id']} duration_s={sample['audio']['duration_s']:.3f} "
                f"hot_median_s={summary['hot_elapsed_median_s']:.3f} "
                f"hot_rtf={summary['hot_rtf_median']:.4f} "
                f"blank={summary['hot_blank_output_count']}/{summary['hot_run_count']} "
                f"text={summary['hot_transcripts'][-1]!r}"
            )


def driver_main(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest).expanduser().resolve()
    manifest = read_manifest(manifest_path)
    selected_ids = args.sample_id or None
    selected_samples = samples_from_manifest(manifest, selected_ids)
    audio_dir = Path(args.audio_dir).expanduser().resolve()
    audio_metadata_list = prepare_corpus(
        manifest_path, audio_dir, manifest, force=args.force_corpus
    )
    selected_audio = [
        item for item in audio_metadata_list if item["sample_id"] in {sample["id"] for sample in selected_samples}
    ]
    if args.prepare_corpus_only:
        print(json.dumps({"manifest": str(manifest_path), "audio": selected_audio}, ensure_ascii=False, indent=2))
        return 0

    model_specs = args.model or [str(DEFAULT_MODEL)]
    models = [parse_model_spec(spec) for spec in model_specs]
    for _, model_path in models:
        if not model_path.is_dir():
            raise FileNotFoundError(f"Model directory does not exist: {model_path}")
    config_names = args.config_name or ["zh_fp16_greedy"]
    for config_name in config_names:
        config_for(config_name)
    if args.hot_runs < 3:
        raise ValueError("--hot-runs must be at least 3")

    started = utc_now()
    runs: list[dict[str, Any]] = []
    # Deliberately sequential: one fresh subprocess per model/config pair.
    for model_label, model_path in models:
        for config_name in config_names:
            command = [
                sys.executable,
                str(SCRIPT_PATH),
                "--worker",
                "--model-path",
                str(model_path),
                "--model-label",
                model_label,
                "--config-name",
                config_name,
                "--manifest",
                str(manifest_path),
                "--audio-dir",
                str(audio_dir),
                "--hot-runs",
                str(args.hot_runs),
            ]
            for sample_id in (args.sample_id or [sample["id"] for sample in selected_samples]):
                command.extend(["--sample-id", sample_id])
            completed = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if completed.returncode != 0:
                stderr = completed.stderr.strip()
                raise RuntimeError(
                    f"Worker failed ({completed.returncode}) for {model_label}/{config_name}:\n"
                    f"command: {shlex.join(command)}\n{stderr}"
                )
            try:
                worker_result = json.loads(completed.stdout)
            except json.JSONDecodeError as exc:
                raise RuntimeError(
                    f"Worker returned invalid JSON for {model_label}/{config_name}: "
                    f"{completed.stdout[:500]!r}\nstderr={completed.stderr[-2000:]!r}"
                ) from exc
            worker_result["driver_command"] = shlex.join(command)
            worker_result["worker_stderr"] = completed.stderr
            runs.append(worker_result)

    finished = utc_now()
    result = {
        "schema_version": 1,
        "result_type": "mlx_whisper_sequential_benchmark",
        "started_at_utc": started,
        "finished_at_utc": finished,
        "driver_command": shlex.join([sys.executable, *sys.argv]),
        "driver_path": str(SCRIPT_PATH),
        "driver_sha256": sha256_file(SCRIPT_PATH),
        "manifest_path": str(manifest_path),
        "manifest_sha256": sha256_file(manifest_path),
        "corpus": {
            "audio_dir": str(audio_dir),
            "source": manifest.get("source"),
            "accuracy_evidence": manifest.get("source", {}).get("accuracy_evidence"),
            "manifest_metadata": {
                key: manifest[key]
                for key in ("manifest_version", "created_at", "purpose", "selection", "dataset")
                if key in manifest
            },
            "audio": selected_audio,
        },
        "runtime": runtime_metadata(),
        "execution": {
            "subprocess_policy": "fresh subprocess for every model/config pair",
            "ordering": "models and configs are run in CLI order, strictly sequentially",
            "hot_runs_requested": args.hot_runs,
            "selected_sample_ids": [sample["id"] for sample in selected_samples],
            "config_names": config_names,
        },
        "runs": runs,
    }
    output_path = Path(args.output).expanduser().resolve() if args.output else (
        SCRIPT_DIR / "results" / f"benchmark_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print_driver_summary(output_path, result)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--model", action="append", help="Model directory or LABEL=PATH; repeatable")
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST), help="Corpus manifest JSON")
    parser.add_argument("--audio-dir", default=str(DEFAULT_AUDIO_DIR), help="Generated WAV directory")
    parser.add_argument("--output", help="Benchmark result JSON path")
    parser.add_argument("--hot-runs", type=int, default=DEFAULT_HOT_RUNS, help="Measured runs per sample (>=3)")
    parser.add_argument("--sample-id", action="append", help="Restrict samples; repeatable")
    parser.add_argument("--config-name", action="append", help="Decoding config; repeatable")
    parser.add_argument("--force-corpus", action="store_true", help="Regenerate synthetic WAV files")
    parser.add_argument("--prepare-corpus-only", action="store_true", help="Generate corpus and exit")
    # Worker-only arguments are intentionally ordinary parser options so the
    # same script can be launched by the driver without a second module.
    parser.add_argument("--model-path", help=argparse.SUPPRESS)
    parser.add_argument("--model-label", default="model", help=argparse.SUPPRESS)
    parser.add_argument("--worker-output", help=argparse.SUPPRESS)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.worker:
        if not args.model_path:
            raise ValueError("--worker requires --model-path")
        return worker_main(args)
    return driver_main(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, RuntimeError, ValueError) as exc:
        print(f"benchmark_models.py: error: {exc}", file=sys.stderr)
        raise SystemExit(2)
