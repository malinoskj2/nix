import argparse
import json
import os
from pathlib import Path
import sys

CATALOG_ALIAS = "whisper-large-v3-turbo"
HUB_MODEL = "large-v3-turbo"


def timestamp(seconds):
    milliseconds = round(seconds * 1000)
    hours, milliseconds = divmod(milliseconds, 3_600_000)
    minutes, milliseconds = divmod(milliseconds, 60_000)
    seconds, milliseconds = divmod(milliseconds, 1000)
    return f"{hours:02}:{minutes:02}:{seconds:02},{milliseconds:03}"


def catalog_model():
    root = os.environ.get("MODEL_ROOT")
    if not root:
        return None, "MODEL_ROOT is not set"
    try:
        entry = json.loads((Path(root) / "readiness.json").read_text())["entries"][CATALOG_ALIAS]
    except (OSError, ValueError, KeyError, TypeError) as error:
        return None, f"no readiness for {CATALOG_ALIAS} in {root} ({type(error).__name__})"
    if entry.get("status") != "ready":
        return None, f"{CATALOG_ALIAS} is {entry.get('status', 'unknown')} in {root}"
    path = Path(root) / "by-name" / CATALOG_ALIAS
    if not (path / "model.bin").is_file():
        return None, f"{path} has no model.bin"
    return path, None


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="media-transcribe", description="Transcribe one local audio/video file, then exit and unload the model."
    )
    parser.add_argument("input", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True, help="New directory for text, JSON and SRT outputs")
    parser.add_argument(
        "--model",
        help=f"Whisper model name or local CTranslate2 model directory; default: the shared catalog's {CATALOG_ALIAS}, "
        f"else {HUB_MODEL} from the faster-whisper cache",
    )
    parser.add_argument("--language", help="Language code; omitted means detect automatically")
    parser.add_argument("--device", choices=["cpu", "cuda"], default="cpu")
    args = parser.parse_args(argv)

    if not args.input.is_file():
        parser.error(f"Input is not a file: {args.input}")
    if args.output_dir.exists():
        parser.error(f"Output directory already exists: {args.output_dir}")
    if args.device == "cuda" and not os.environ.get("GPU_LEASE_ID"):
        parser.error("CUDA transcription requires a GPU reservation: gpu-run --vram 4GiB --name transcription -- ...")

    from faster_whisper import WhisperModel

    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "faster-whisper"
    options = {"download_root": str(cache)}
    if args.model is None:
        local, reason = catalog_model()
        if local:
            args.model = str(local)
            options = {"local_files_only": True}
        else:
            args.model = HUB_MODEL
            print(
                f"media-transcribe: catalog model unavailable: {reason}; falling back to {HUB_MODEL} in {cache}, "
                "which may download it. On the host, run `systemctl --user start local-models-sync.service` "
                "and check `local-models status`.",
                file=sys.stderr,
            )
    model = WhisperModel(
        args.model,
        device=args.device,
        compute_type="float16" if args.device == "cuda" else "int8",
        **options,
    )
    args.output_dir.mkdir(parents=True, exist_ok=False)
    segments, info = model.transcribe(str(args.input), language=args.language, vad_filter=True)
    records = []
    with (args.output_dir / "transcript.txt").open("x") as text, (args.output_dir / "transcript.srt").open("x") as srt:
        for index, segment in enumerate(segments, 1):
            content = segment.text.strip()
            records.append({"start": segment.start, "end": segment.end, "text": content})
            text.write(content + "\n")
            srt.write(f"{index}\n{timestamp(segment.start)} --> {timestamp(segment.end)}\n{content}\n\n")
    with (args.output_dir / "transcript.json").open("x") as output:
        json.dump(
            {
                "input": str(args.input.resolve()),
                "model": args.model,
                "language": info.language,
                "language_probability": info.language_probability,
                "segments": records,
            },
            output,
            ensure_ascii=False,
            indent=2,
        )
        output.write("\n")
    print(args.output_dir.resolve())


if __name__ == "__main__":
    main()
