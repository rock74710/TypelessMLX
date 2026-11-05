"""Small, network-free checks for model integrity and readiness markers."""

import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path

from model_validation import (
    ModelValidationError,
    check_ready_marker,
    load_model_manifest,
    publish_staged_artifact,
    read_conversion_provenance,
    read_quantization_provenance,
    validate_and_mark,
)


def git_blob_sha1(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode("ascii")
    return hashlib.sha1(header + data).hexdigest()


class ModelValidationTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name) / "model"
        self.root.mkdir()
        self.marker_root = Path(self.tempdir.name) / "markers"
        self.config = b'{"model_type":"whisper"}\n'
        self.weights = b"tiny deterministic weights"
        (self.root / "config.json").write_bytes(self.config)
        (self.root / "weights.safetensors").write_bytes(self.weights)
        self.files = {
            "config.json": {
                "size": len(self.config),
                "algorithm": "git-sha1",
                "digest": git_blob_sha1(self.config),
            },
            "weights.safetensors": {
                "size": len(self.weights),
                "algorithm": "sha256",
                "digest": hashlib.sha256(self.weights).hexdigest(),
            },
        }

    def tearDown(self):
        self.tempdir.cleanup()

    def test_required_file_missing_is_not_ready(self):
        (self.root / "weights.safetensors").unlink()
        with self.assertRaises(ModelValidationError):
            validate_and_mark(
                model_id="fixture",
                model_path=self.root,
                revision="fixture-revision",
                files=self.files,
                loader=lambda _path: None,
                marker_root=self.marker_root,
            )

    def test_wrong_size_or_trusted_hash_is_not_ready(self):
        (self.root / "weights.safetensors").write_bytes(b"corrupted bytes!!!!!")
        with self.assertRaises(ModelValidationError):
            validate_and_mark(
                model_id="fixture",
                model_path=self.root,
                revision="fixture-revision",
                files=self.files,
                loader=lambda _path: None,
                marker_root=self.marker_root,
            )

    def test_same_size_content_corruption_fails_trusted_hash(self):
        corrupted = b"x" + self.weights[1:]
        self.assertEqual(len(corrupted), len(self.weights))
        (self.root / "weights.safetensors").write_bytes(corrupted)
        with self.assertRaisesRegex(ModelValidationError, "mismatch"):
            validate_and_mark(
                model_id="fixture",
                model_path=self.root,
                revision="fixture-revision",
                files=self.files,
                loader=lambda _path: None,
                marker_root=self.marker_root,
            )

    def test_loader_failure_never_writes_ready_marker(self):
        def reject_load(_path):
            raise RuntimeError("fixture loader rejected the model")

        with self.assertRaises(RuntimeError):
            validate_and_mark(
                model_id="fixture",
                model_path=self.root,
                revision="fixture-revision",
                files=self.files,
                loader=reject_load,
                marker_root=self.marker_root,
            )
        ready, _reason = check_ready_marker(
            model_id="fixture",
            model_path=self.root,
            revision="fixture-revision",
            files=self.files,
            marker_root=self.marker_root,
        )
        self.assertFalse(ready)

    def test_success_writes_marker_and_unchanged_startup_skips_loader(self):
        calls = []
        validate_and_mark(
            model_id="fixture",
            model_path=self.root,
            revision="fixture-revision",
            files=self.files,
            loader=lambda _path: calls.append("load"),
            marker_root=self.marker_root,
        )
        ready, reason = check_ready_marker(
            model_id="fixture",
            model_path=self.root,
            revision="fixture-revision",
            files=self.files,
            marker_root=self.marker_root,
        )
        self.assertTrue(ready, reason)
        self.assertEqual(calls, ["load"])

    def test_file_change_invalidates_marker(self):
        validate_and_mark(
            model_id="fixture",
            model_path=self.root,
            revision="fixture-revision",
            files=self.files,
            loader=lambda _path: None,
            marker_root=self.marker_root,
        )
        weight_path = self.root / "weights.safetensors"
        original_mtime = weight_path.stat().st_mtime_ns
        weight_path.write_bytes(self.weights + b"x")
        os.utime(weight_path, ns=(original_mtime + 2_000_000, original_mtime + 2_000_000))
        ready, reason = check_ready_marker(
            model_id="fixture",
            model_path=self.root,
            revision="fixture-revision",
            files=self.files,
            marker_root=self.marker_root,
        )
        self.assertFalse(ready)
        self.assertIn("fingerprint", reason.lower())

    def test_incomplete_marker_is_not_ready(self):
        marker_path = self.marker_root / "fixture.json"
        marker_path.parent.mkdir(parents=True, exist_ok=True)
        marker_path.write_text('{"status":"ready"}', encoding="utf-8")
        ready, _reason = check_ready_marker(
            model_id="fixture",
            model_path=self.root,
            revision="fixture-revision",
            files=self.files,
            marker_root=self.marker_root,
        )
        self.assertFalse(ready)

    def test_marker_for_an_old_revision_is_not_ready(self):
        validate_and_mark(
            model_id="fixture",
            model_path=self.root,
            revision="old-revision",
            files=self.files,
            loader=lambda _path: None,
            marker_root=self.marker_root,
        )
        ready, reason = check_ready_marker(
            model_id="fixture",
            model_path=self.root,
            revision="new-revision",
            files=self.files,
            marker_root=self.marker_root,
        )
        self.assertFalse(ready)
        self.assertIn("revision", reason.lower())

    def test_fixed_manifest_covers_every_selectable_python_model(self):
        manifest = load_model_manifest()
        models = manifest["models"]
        for model_id in (
            "qwen3-asr-0.6b",
            "breeze-asr-25",
            "whisper-large-v3",
            "whisper-medium",
            "whisper-small",
        ):
            with self.subTest(model_id=model_id):
                spec = models[model_id]
                self.assertRegex(spec["revision"], r"^[0-9a-f]{40}$")
                self.assertTrue(spec["required_files"])
                for file_spec in spec["required_files"].values():
                    self.assertGreater(file_spec["size"], 0)
                    self.assertRegex(file_spec["digest"], r"^[0-9a-f]{40,64}$")

    def test_conversion_manifest_links_output_to_fixed_source_revision(self):
        source_spec = {
            "repo_id": "fixture/source",
            "revision": "1234567890abcdef1234567890abcdef12345678",
            "required_files": {
                "config.json": {
                    "size": 5,
                    "algorithm": "git-sha1",
                    "digest": "trusted-source-config",
                }
            },
        }
        output_config = b"config"
        output_weights = b"converted weights"
        (self.root / "config.json").write_bytes(output_config)
        (self.root / "weights.safetensors").write_bytes(output_weights)
        output_manifest = {
            "format": "typelessmlx-conversion-v1",
            "source": {
                "repo_id": source_spec["repo_id"],
                "revision": source_spec["revision"],
                "trusted_files": source_spec["required_files"],
            },
            "conversion": {
                "dtype": "float16",
                "tools": {"mlx": "0.31.1", "mlx_whisper": "0.4.3", "torch": "2.0"},
            },
            "outputs": {
                "config.json": {
                    "size": len(output_config),
                    "sha256": hashlib.sha256(output_config).hexdigest(),
                },
                "weights.safetensors": {
                    "size": len(output_weights),
                    "sha256": hashlib.sha256(output_weights).hexdigest(),
                },
            },
        }
        (self.root / "conversion_manifest.json").write_text(
            json.dumps(output_manifest), encoding="utf-8"
        )

        files, provenance = read_conversion_provenance(self.root, source_spec)

        self.assertEqual(provenance["source"]["revision"], source_spec["revision"])
        self.assertIn("conversion_manifest.json", files)
        self.assertEqual(files["weights.safetensors"]["digest"], hashlib.sha256(output_weights).hexdigest())

    def test_conversion_manifest_rejects_unexpected_source_or_changed_output(self):
        source_spec = {
            "repo_id": "fixture/source",
            "revision": "1234567890abcdef1234567890abcdef12345678",
            "required_files": {"config.json": {"size": 1, "algorithm": "git-sha1", "digest": "x"}},
        }
        (self.root / "config.json").write_bytes(b"config")
        (self.root / "weights.safetensors").write_bytes(b"converted weights")
        output_manifest = {
            "format": "typelessmlx-conversion-v1",
            "source": {
                "repo_id": "other/source",
                "revision": source_spec["revision"],
                "trusted_files": source_spec["required_files"],
            },
            "conversion": {
                "dtype": "float16",
                "tools": {"mlx": "0.31.1", "mlx_whisper": "0.4.3", "torch": "2.0"},
            },
            "outputs": {},
        }
        (self.root / "conversion_manifest.json").write_text(
            json.dumps(output_manifest), encoding="utf-8"
        )
        with self.assertRaises(ModelValidationError):
            read_conversion_provenance(self.root, source_spec)

    def test_quantization_manifest_can_link_to_pinned_remote_source(self):
        source_provenance = {
            "type": "huggingface-remote",
            "source": {
                "repo_id": "schsu/breeze-asr-25-mlx",
                "revision": "6e48985d562fcf19e80daf8bebf84fb994fb3cc7",
            },
            "outputs": {
                "config.json": {
                    "size": 268,
                    "sha256": "77d68bd8db0be90465fd7d35f8e4fa418297e449a27525060517a7e0df432c4b",
                },
                "weights.safetensors": {
                    "size": 3082909389,
                    "sha256": "c75f7bf32b82421d73d5e6f198883a60863613ae63cb59dc66a78edd72c62364",
                },
            },
        }
        config = b"local quantized config"
        weights = b"local quantized weights"
        (self.root / "config.json").write_bytes(config)
        (self.root / "weights.safetensors").write_bytes(weights)
        quant_manifest = {
            "source_model": {
                "config_file_bytes": source_provenance["outputs"]["config.json"]["size"],
                "config_sha256": source_provenance["outputs"]["config.json"]["sha256"],
                "weights_file_bytes": source_provenance["outputs"]["weights.safetensors"]["size"],
                "weights_sha256": source_provenance["outputs"]["weights.safetensors"]["sha256"],
            },
            "quantization": {"bits": 8, "group_size": 64, "mode": "affine"},
            "loader": "mlx_whisper.load_models.load_model",
            "mlx_whisper_version": "0.4.3",
            "files": {
                "config_file_bytes": len(config),
                "config_sha256": hashlib.sha256(config).hexdigest(),
                "weights_file_bytes": len(weights),
                "weights_sha256": hashlib.sha256(weights).hexdigest(),
            },
        }
        (self.root / "quantization_manifest.json").write_text(
            json.dumps(quant_manifest), encoding="utf-8"
        )

        files, provenance = read_quantization_provenance(self.root, source_provenance)

        self.assertEqual(files["weights.safetensors"]["size"], len(weights))
        self.assertEqual(provenance["source"]["source"]["revision"], source_provenance["source"]["revision"])

    def test_failed_publish_restores_the_previous_usable_artifact(self):
        target = Path(self.tempdir.name) / "release"
        staging = Path(self.tempdir.name) / ".release.staging"
        target.mkdir()
        staging.mkdir()
        (target / "weights.safetensors").write_bytes(b"last-good")
        (staging / "weights.safetensors").write_bytes(b"replacement")
        real_rename = os.rename
        call_count = 0

        def fail_staging_rename(source, destination):
            nonlocal call_count
            call_count += 1
            if call_count == 2:
                raise OSError("simulated interrupted replacement")
            return real_rename(source, destination)

        with self.assertRaisesRegex(OSError, "simulated interrupted"):
            publish_staged_artifact(staging, target, rename=fail_staging_rename)

        self.assertEqual((target / "weights.safetensors").read_bytes(), b"last-good")
        self.assertTrue(staging.is_dir())


if __name__ == "__main__":
    unittest.main()
