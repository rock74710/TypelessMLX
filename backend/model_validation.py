"""Integrity checks shared by model setup, startup status, and conversion."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import contextlib
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


MARKER_SCHEMA_VERSION = 1
READY_MARKER_NAME = ".typelessmlx-model-ready.json"
MANIFEST_PATH = Path(__file__).with_name("model_manifest.json")


class ModelValidationError(RuntimeError):
    """A model does not meet its pinned integrity or readiness contract."""


def load_model_manifest(path: Path | str = MANIFEST_PATH) -> dict[str, Any]:
    try:
        manifest = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ModelValidationError(f"Could not read the model manifest: {exc}") from exc
    if manifest.get("schema_version") != 1:
        raise ModelValidationError("Unsupported model manifest schema version")
    return manifest


MODEL_MANIFEST = load_model_manifest()


def model_marker_path(
    model_id: str,
    model_path: Path | str,
    marker_root: Path | str | None = None,
) -> Path:
    resolved = str(Path(model_path).expanduser().resolve())
    if marker_root is None:
        return Path(resolved) / READY_MARKER_NAME
    key = hashlib.sha256(f"{model_id}\0{resolved}".encode("utf-8")).hexdigest()
    return Path(marker_root).expanduser() / f"{key}.json"


def _relative_file_path(name: str) -> Path:
    path = Path(name)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ModelValidationError(f"Unsafe model file path: {name}")
    return path


def file_fingerprint(model_path: Path | str, names: list[str]) -> list[dict[str, Any]]:
    root = Path(model_path).expanduser()
    fingerprint: list[dict[str, Any]] = []
    for name in sorted(names):
        path = root / _relative_file_path(name)
        try:
            info = path.stat()
        except OSError as exc:
            raise ModelValidationError(f"Required file is missing: {name}") from exc
        if not path.is_file():
            raise ModelValidationError(f"Required path is not a file: {name}")
        fingerprint.append(
            {
                "path": name,
                "size": info.st_size,
                "mtime_ms": info.st_mtime_ns // 1_000_000,
                "inode": getattr(info, "st_ino", 0),
                "device": getattr(info, "st_dev", 0),
            }
        )
    return fingerprint


def _hash_file(path: Path, algorithm: str, byte_count: int) -> str:
    try:
        digest = hashlib.new("sha1" if algorithm == "sha1-git-blob" else algorithm)
    except ValueError as exc:
        raise ModelValidationError(f"Unsupported trusted hash algorithm: {algorithm}") from exc
    if algorithm == "sha1-git-blob":
        digest.update(f"blob {byte_count}\0".encode("ascii"))
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _hash_file_multiple(path: Path, algorithms: set[str], byte_count: int) -> dict[str, str]:
    digests: dict[str, Any] = {}
    for algorithm in algorithms:
        hash_name = "sha1" if algorithm == "sha1-git-blob" else algorithm
        try:
            digest = hashlib.new(hash_name)
        except ValueError as exc:
            raise ModelValidationError(f"Unsupported trusted hash algorithm: {algorithm}") from exc
        if algorithm == "sha1-git-blob":
            digest.update(f"blob {byte_count}\0".encode("ascii"))
        digests[algorithm] = digest
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            for digest in digests.values():
                digest.update(chunk)
    return {name: digest.hexdigest() for name, digest in digests.items()}


def verify_files(model_path: Path | str, files: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Check trusted byte counts and digests, then return local SHA-256 values."""
    root = Path(model_path).expanduser()
    actual: dict[str, dict[str, Any]] = {}
    for name, expected in files.items():
        path = root / _relative_file_path(name)
        try:
            size = path.stat().st_size
        except OSError as exc:
            raise ModelValidationError(f"Required file is missing: {name}") from exc
        if not path.is_file():
            raise ModelValidationError(f"Required path is not a file: {name}")
        expected_size = int(expected["size"])
        if size != expected_size:
            raise ModelValidationError(
                f"Wrong size for {name}: expected {expected_size}, found {size}"
            )
        algorithm = expected["algorithm"]
        hash_algorithm = "sha1-git-blob" if algorithm == "git-sha1" else algorithm
        digests = _hash_file_multiple(path, {hash_algorithm, "sha256"}, size)
        actual_digest = digests[hash_algorithm]
        if actual_digest.lower() != str(expected["digest"]).lower():
            raise ModelValidationError(f"Trusted {algorithm} mismatch for {name}")
        actual[name] = {
            "size": size,
            "sha256": digests["sha256"],
        }
    return actual


def check_ready_marker(
    *,
    model_id: str,
    model_path: Path | str,
    revision: str,
    files: dict[str, dict[str, Any]],
    marker_root: Path | str | None = None,
) -> tuple[bool, str]:
    marker_path = model_marker_path(model_id, model_path, marker_root)
    try:
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return False, "Readiness marker is missing"
    except (OSError, json.JSONDecodeError):
        return False, "Readiness marker is incomplete or invalid"
    if marker.get("schema_version") != MARKER_SCHEMA_VERSION:
        return False, "Readiness marker schema changed"
    if marker.get("status") != "ready":
        return False, "Readiness marker is not complete"
    if marker.get("model_id") != model_id or marker.get("revision") != revision:
        return False, "Readiness marker does not match the pinned model revision"
    resolved = str(Path(model_path).expanduser().resolve())
    if marker.get("model_path") != resolved:
        return False, "Readiness marker path does not match the model"
    names = list(files.keys())
    try:
        current = file_fingerprint(model_path, names)
    except ModelValidationError as exc:
        return False, str(exc)
    if marker.get("fingerprint") != current:
        return False, "Model file fingerprint changed"
    if marker.get("required_files") != sorted(names):
        return False, "Readiness marker required-file list changed"
    if not marker.get("loader"):
        return False, "Readiness marker has no successful loader record"
    return True, "Ready"


def ready_marker_data(
    *,
    model_id: str,
    model_path: Path | str,
    revision: str,
    files: dict[str, dict[str, Any]],
    marker_root: Path | str | None = None,
) -> dict[str, Any] | None:
    ready, _reason = check_ready_marker(
        model_id=model_id,
        model_path=model_path,
        revision=revision,
        files=files,
        marker_root=marker_root,
    )
    if not ready:
        return None
    try:
        return json.loads(
            model_marker_path(model_id, model_path, marker_root).read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError):
        return None


def _atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        path.parent.chmod(0o700)
    except OSError:
        pass
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(data, output, ensure_ascii=False, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        try:
            temporary.chmod(0o600)
        except OSError:
            pass
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def validate_and_mark(
    *,
    model_id: str,
    model_path: Path | str,
    revision: str,
    files: dict[str, dict[str, Any]],
    loader: Callable[[Path], Any],
    marker_root: Path | str | None = None,
    provenance: dict[str, Any] | None = None,
    loader_name: str = "model loader",
) -> dict[str, Any]:
    """Verify contents, load the artifact, then atomically record readiness."""
    ready, _reason = check_ready_marker(
        model_id=model_id,
        model_path=model_path,
        revision=revision,
        files=files,
        marker_root=marker_root,
    )
    if ready:
        return {"status": "ready", "cached": True}

    root = Path(model_path).expanduser().resolve()
    local_hashes = verify_files(root, files)
    before_load = file_fingerprint(root, list(files.keys()))
    with contextlib.redirect_stdout(sys.stderr):
        loader_result = loader(root)
    if loader_result is False:
        raise ModelValidationError(f"{loader_name} rejected the model")
    after_load = file_fingerprint(root, list(files.keys()))
    if before_load != after_load:
        raise ModelValidationError("Model files changed during loader validation")

    marker = {
        "schema_version": MARKER_SCHEMA_VERSION,
        "status": "ready",
        "model_id": model_id,
        "revision": revision,
        "model_path": str(root),
        "required_files": sorted(files.keys()),
        "fingerprint": after_load,
        "local_file_sha256": local_hashes,
        "provenance": provenance or {"type": "remote", "revision": revision},
        "loader": loader_name,
        "validated_at": datetime.now(timezone.utc).isoformat(),
    }
    _atomic_write_json(model_marker_path(model_id, root, marker_root), marker)
    return {"status": "ready", "cached": False, "marker": marker}


def cache_snapshot_path(repo_id: str, revision: str, home: Path | str | None = None) -> Path:
    root = Path(home).expanduser() if home else Path.home()
    repo_cache = "models--" + repo_id.replace("/", "--")
    return root / ".cache/huggingface/hub" / repo_cache / "snapshots" / revision


def remote_model_spec(model_id: str) -> dict[str, Any]:
    try:
        return MODEL_MANIFEST["models"][model_id]
    except KeyError as exc:
        raise ModelValidationError(f"No fixed remote model specification for {model_id}") from exc


def read_conversion_provenance(
    model_path: Path | str,
    expected_source: dict[str, Any],
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    """Check a local FP16 conversion record against its fixed remote source."""
    root = Path(model_path).expanduser()
    manifest_path = root / "conversion_manifest.json"
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ModelValidationError(f"Conversion provenance is missing or invalid: {exc}") from exc

    source = data.get("source") or {}
    expected = {
        "repo_id": expected_source["repo_id"],
        "revision": expected_source["revision"],
        "trusted_files": expected_source["required_files"],
    }
    if data.get("format") != "typelessmlx-conversion-v1" or source != expected:
        raise ModelValidationError("Conversion provenance does not match the fixed Breeze source")
    conversion = data.get("conversion") or {}
    tools = conversion.get("tools") or {}
    if conversion.get("dtype") != "float16" or not all(
        tools.get(name) for name in ("mlx", "mlx_whisper", "torch")
    ):
        raise ModelValidationError("Conversion provenance is missing its dtype or tool versions")

    outputs = data.get("outputs") or {}
    file_specs: dict[str, dict[str, Any]] = {}
    for name in ("config.json", "weights.safetensors"):
        try:
            output = outputs[name]
            size = int(output["size"])
            digest = str(output["sha256"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ModelValidationError(f"Conversion provenance is missing output {name}") from exc
        if size <= 0 or len(digest) != 64:
            raise ModelValidationError(f"Conversion provenance has invalid output metadata for {name}")
        file_specs[name] = {"size": size, "algorithm": "sha256", "digest": digest}

    output_hashes: dict[str, dict[str, Any]] = {}
    for name, expected_output in file_specs.items():
        try:
            actual_size = (root / name).stat().st_size
        except OSError as exc:
            raise ModelValidationError(f"Converted output is missing: {name}") from exc
        if actual_size != int(expected_output["size"]):
            raise ModelValidationError(f"Converted output has the wrong size: {name}")
        output_hashes[name] = {
            "size": actual_size,
            "sha256": str(expected_output["digest"]),
        }
    try:
        manifest_size = manifest_path.stat().st_size
    except OSError as exc:
        raise ModelValidationError("Conversion provenance file disappeared") from exc
    manifest_digest = _hash_file(manifest_path, "sha256", manifest_size)
    file_specs["conversion_manifest.json"] = {
        "size": manifest_size,
        "algorithm": "sha256",
        "digest": manifest_digest,
    }
    provenance = {
        "type": "local-conversion-record",
        "source": source,
        "conversion": conversion,
        "outputs": output_hashes,
    }
    return file_specs, provenance


def read_quantization_provenance(
    model_path: Path | str,
    source_provenance: dict[str, Any],
    expected_bits: int = 8,
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    """Link a local Breeze quantization record to a verified FP16 source."""
    root = Path(model_path).expanduser()
    manifest_path = root / "quantization_manifest.json"
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ModelValidationError(f"Quantization provenance is missing or invalid: {exc}") from exc

    source = data.get("source_model") or {}
    source_outputs = source_provenance.get("outputs") or {}
    expected_source = {
        "weights_sha256": source_outputs.get("weights.safetensors", {}).get("sha256"),
        "config_sha256": source_outputs.get("config.json", {}).get("sha256"),
        "weights_file_bytes": source_outputs.get("weights.safetensors", {}).get("size"),
        "config_file_bytes": source_outputs.get("config.json", {}).get("size"),
    }
    if (
        not expected_source["weights_sha256"]
        or not expected_source["config_sha256"]
        or not expected_source["weights_file_bytes"]
        or not expected_source["config_file_bytes"]
    ):
        raise ModelValidationError("Verified FP16 provenance has no output hashes")
    if (
        source.get("weights_sha256") != expected_source["weights_sha256"]
        or source.get("config_sha256") != expected_source["config_sha256"]
        or source.get("weights_file_bytes") != expected_source["weights_file_bytes"]
        or source.get("config_file_bytes") != expected_source["config_file_bytes"]
    ):
        raise ModelValidationError("8-bit artifact does not match the verified FP16 source")

    quantization = data.get("quantization") or {}
    if (
        int(quantization.get("bits", 0)) != expected_bits
        or int(quantization.get("group_size", 0)) != 64
        or quantization.get("mode") != "affine"
    ):
        raise ModelValidationError("Breeze 8-bit quantization settings are not supported")
    if data.get("loader") != "mlx_whisper.load_models.load_model":
        raise ModelValidationError("Quantization record does not name the MLX Whisper loader")

    outputs = data.get("files") or {}
    try:
        config_size = int(outputs["config_file_bytes"])
        config_hash = str(outputs["config_sha256"])
        weights_size = int(outputs["weights_file_bytes"])
        weights_hash = str(outputs["weights_sha256"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ModelValidationError("Quantization provenance has no output file hashes") from exc
    file_specs = {
        "config.json": {"size": config_size, "algorithm": "sha256", "digest": config_hash},
        "weights.safetensors": {"size": weights_size, "algorithm": "sha256", "digest": weights_hash},
    }
    for name, expected_output in file_specs.items():
        try:
            actual_size = (root / name).stat().st_size
        except OSError as exc:
            raise ModelValidationError(f"Quantized output is missing: {name}") from exc
        if actual_size != int(expected_output["size"]):
            raise ModelValidationError(f"Quantized output has the wrong size: {name}")
    output_hashes = {
        name: {"size": int(spec["size"]), "sha256": str(spec["digest"])}
        for name, spec in file_specs.items()
    }
    try:
        manifest_size = manifest_path.stat().st_size
    except OSError as exc:
        raise ModelValidationError("Quantization provenance file disappeared") from exc
    manifest_digest = _hash_file(manifest_path, "sha256", manifest_size)
    file_specs["quantization_manifest.json"] = {
        "size": manifest_size,
        "algorithm": "sha256",
        "digest": manifest_digest,
    }
    provenance = {
        "type": "local-quantization-record",
        "source": source_provenance,
        "quantization": quantization,
        "loader": data.get("loader"),
        "mlx_whisper_version": data.get("mlx_whisper_version"),
        "outputs": output_hashes,
    }
    return file_specs, provenance


def find_ready_remote_path(model_id: str, home: Path | str | None = None) -> Path | None:
    spec = remote_model_spec(model_id)
    path = cache_snapshot_path(spec["repo_id"], spec["revision"], home)
    if path.is_dir():
        return path
    return None


def model_cache_size(path: Path | str) -> int:
    root = Path(path)
    total = 0
    if not root.is_dir():
        return total
    for entry in root.rglob("*"):
        try:
            if entry.is_file():
                total += entry.stat().st_size
        except OSError:
            continue
    return total


def publish_staged_artifact(
    staging_path: Path | str,
    target_path: Path | str,
    rename: Callable[[Path, Path], Any] | None = None,
) -> None:
    """Replace a model directory and restore the previous directory on failure."""
    staging = Path(staging_path)
    target = Path(target_path)
    if staging.parent.resolve() != target.parent.resolve():
        raise ModelValidationError("Staging and target directories must share a parent")
    if not staging.is_dir():
        raise ModelValidationError("Staging directory is missing")
    rename_path = rename or (lambda source, destination: os.rename(source, destination))
    backup = target.parent / f".{target.name}.backup-{uuid.uuid4().hex}"
    moved_old = False
    if target.exists():
        rename_path(target, backup)
        moved_old = True
    try:
        rename_path(staging, target)
    except Exception:
        if moved_old and backup.exists() and not target.exists():
            rename_path(backup, target)
        raise
    if moved_old and backup.exists():
        shutil.rmtree(backup)
