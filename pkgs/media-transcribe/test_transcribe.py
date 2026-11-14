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

    def test_lazy_segments_are_consumed_and_written_with_timestamps(self):
        model = Mock()
        model.transcribe.return_value = (
            iter([SimpleNamespace(start=59.9996, end=61.25, text=" Hello world. ")]),
            SimpleNamespace(language="en", language_probability=0.99),
        )
        factory = Mock(return_value=model)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "audio.wav"
            source.touch()
            output = source.parent / "out"
            with (
                patch.dict("sys.modules", {"faster_whisper": SimpleNamespace(WhisperModel=factory)}),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                transcribe.main([str(source), "--output-dir", str(output)])
            self.assertEqual((output / "transcript.txt").read_text(), "Hello world.\n")
            self.assertIn("00:01:00,000 --> 00:01:01,250", (output / "transcript.srt").read_text())
            data = json.loads((output / "transcript.json").read_text())
            self.assertEqual(data["language"], "en")
            self.assertEqual(len(data["segments"]), 1)
            self.assertEqual(factory.call_args.kwargs["device"], "cpu")
            model.transcribe.assert_called_once_with(str(source), language=None, vad_filter=True)


if __name__ == "__main__":
    unittest.main()
