import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import transcribe


class TranscribeTests(unittest.TestCase):
    def test_help_does_not_import_the_model(self):
        with patch.dict("sys.modules", {"faster_whisper": None}), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                transcribe.main(["--help"])
        self.assertEqual(error.exception.code, 0)

    def test_cuda_requires_a_reservation_before_loading_the_model(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "audio.wav"
            source.touch()
            with (
                patch.dict(os.environ, {}, clear=True),
                patch.dict("sys.modules", {"faster_whisper": None}),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                with self.assertRaises(SystemExit) as error:
                    transcribe.main([str(source), "--device", "cuda", "--output-dir", str(source.parent / "out")])
            self.assertEqual(error.exception.code, 2)
            self.assertFalse((source.parent / "out").exists())

    def test_existing_outputs_are_preserved_without_loading_the_model(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "audio.wav"
            source.touch()
            with patch.dict("sys.modules", {"faster_whisper": None}), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    transcribe.main([str(source), "--output-dir", directory])

    def run_with_model(self, directory, environment, argv=()):
        model = Mock()
        model.transcribe.return_value = (
            iter([SimpleNamespace(start=59.9996, end=61.25, text=" Hello world. ")]),
            SimpleNamespace(language="en", language_probability=0.99),
        )
        factory = Mock(return_value=model)
        source = Path(directory) / "audio.wav"
        source.touch()
        output = source.parent / "out"
        stderr = io.StringIO()
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.dict("sys.modules", {"faster_whisper": SimpleNamespace(WhisperModel=factory)}),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(stderr),
        ):
            transcribe.main([str(source), "--output-dir", str(output), *argv])
        return source, output, model, factory, stderr.getvalue()

    def catalog(self, directory, status):
        root = Path(directory) / "models"
        alias = root / "by-name" / transcribe.CATALOG_ALIAS
        alias.mkdir(parents=True)
        (alias / "model.bin").touch()
        (root / "readiness.json").write_text(json.dumps({"entries": {transcribe.CATALOG_ALIAS: {"status": status}}}))
        return root, alias

    def test_lazy_segments_are_consumed_and_written_with_timestamps(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output, model, factory, _ = self.run_with_model(directory, {"HOME": directory})
            self.assertEqual((output / "transcript.txt").read_text(), "Hello world.\n")
            self.assertIn("00:01:00,000 --> 00:01:01,250", (output / "transcript.srt").read_text())
            data = json.loads((output / "transcript.json").read_text())
            self.assertEqual(data["language"], "en")
            self.assertEqual(len(data["segments"]), 1)
            self.assertEqual(factory.call_args.kwargs["device"], "cpu")
            model.transcribe.assert_called_once_with(str(source), language=None, vad_filter=True)

    def test_ready_catalog_alias_is_the_offline_default(self):
        with tempfile.TemporaryDirectory() as directory:
            root, alias = self.catalog(directory, "ready")
            *_, factory, stderr = self.run_with_model(directory, {"HOME": directory, "MODEL_ROOT": str(root)})
            self.assertEqual(factory.call_args.args, (str(alias),))
            self.assertTrue(factory.call_args.kwargs["local_files_only"])
            self.assertNotIn("download_root", factory.call_args.kwargs)
            self.assertEqual(stderr, "")

    def test_unready_alias_falls_back_to_the_cache_with_a_message(self):
        with tempfile.TemporaryDirectory() as directory:
            root, _ = self.catalog(directory, "missing")
            *_, factory, stderr = self.run_with_model(directory, {"HOME": directory, "MODEL_ROOT": str(root)})
            self.assertEqual(factory.call_args.args, (transcribe.HUB_MODEL,))
            self.assertEqual(factory.call_args.kwargs["download_root"], str(Path(directory) / ".cache/faster-whisper"))
            self.assertNotIn("local_files_only", factory.call_args.kwargs)
            self.assertIn("is missing", stderr)
            self.assertIn("local-models-sync.service", stderr)

    def test_missing_model_root_falls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            *_, factory, stderr = self.run_with_model(directory, {"HOME": directory})
            self.assertEqual(factory.call_args.args, (transcribe.HUB_MODEL,))
            self.assertIn("MODEL_ROOT is not set", stderr)

    def test_explicit_model_skips_the_catalog(self):
        with tempfile.TemporaryDirectory() as directory:
            root, _ = self.catalog(directory, "ready")
            *_, factory, stderr = self.run_with_model(
                directory, {"HOME": directory, "MODEL_ROOT": str(root)}, ["--model", "small"]
            )
            self.assertEqual(factory.call_args.args, ("small",))
            self.assertIn("download_root", factory.call_args.kwargs)
            self.assertEqual(stderr, "")


if __name__ == "__main__":
    unittest.main()
