"""The backend must return the recognizer's text without cleanup edits."""

import sys
import types
import unittest
from unittest.mock import patch

import transcribe_server


class RawTranscriptionTests(unittest.TestCase):
    def test_whisper_result_keeps_fillers_and_does_not_add_punctuation(self):
        fake = types.SimpleNamespace(
            transcribe=lambda *args, **kwargs: {"text": "呃，原始辨識結果"}
        )
        with patch.dict(sys.modules, {"mlx_whisper": fake}), patch.object(
            transcribe_server, "require_ready_model_path", return_value="/verified/model"
        ):
            result = transcribe_server.transcribe(
                "/fixture.wav",
                "/untrusted/model",
                "zh",
                remove_fillers=True,
            )
        self.assertEqual(result, "呃，原始辨識結果")

    def test_qwen_result_keeps_raw_model_output(self):
        generated = types.SimpleNamespace(text="嗯 原始辨識結果")
        utils_module = types.ModuleType("mlx_audio.stt.utils")
        utils_module.load_model = lambda _path: object()
        generate_module = types.ModuleType("mlx_audio.stt.generate")

        def generate_transcription(**kwargs):
            self.assertIn("保留語氣詞", kwargs["system_prompt"])
            return generated

        generate_module.generate_transcription = generate_transcription
        package = types.ModuleType("mlx_audio")
        package.__path__ = []
        stt_package = types.ModuleType("mlx_audio.stt")
        stt_package.__path__ = []
        modules = {
            "mlx_audio": package,
            "mlx_audio.stt": stt_package,
            "mlx_audio.stt.utils": utils_module,
            "mlx_audio.stt.generate": generate_module,
        }
        with patch.dict(sys.modules, modules):
            transcribe_server._qwen3_model = None
            transcribe_server._qwen3_model_path = None
            result = transcribe_server.transcribe_qwen3(
                "/fixture.wav", "/verified/qwen", "zh", remove_fillers=True
            )
        self.assertEqual(result, "嗯 原始辨識結果")


if __name__ == "__main__":
    unittest.main()
