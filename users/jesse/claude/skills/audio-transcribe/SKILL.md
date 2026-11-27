---
name: audio-transcribe
description: Transcribe a local audio or video file to text, timestamped JSON and subtitles using faster-whisper. Load the model only for the requested transcription and exit when complete; use video-download first for an online video URL.
---

# Audio transcription

Use the Nix-installed `media-transcribe` command. It runs faster-whisper as a
foreground batch job, not a service. The model is loaded only by this command
and released when its process exits. Do not start a daemon, preload or warm a
model at login, or leave a transcription worker running after the task.

Use a local input file, retrieving archived assets first if necessary. Pick a
new output-directory path under `.tmp/audio-transcribe/`; the command creates
that directory and refuses to overwrite an existing one.

On the RTX 5090, acquire the shared GPU reservation before loading the model:

```sh
gpu-run --vram 4GiB --name "audio transcription" -- \
  media-transcribe "$input_file" --device cuda --output-dir "$new_output_dir"
```

If `GPU_LEASE_ID` is already set, run `media-transcribe` directly within that
reservation instead of nesting one. Use a larger reservation for a model whose
peak needs it. On a host without a supported GPU, use `--device cpu` (int8)
without a GPU reservation. CUDA execution is built for this setup's Blackwell
GPU; CPU execution also works on the other hosts.

The default model is the shared catalog's `whisper-large-v3-turbo` alias
(`$MODEL_ROOT/by-name/whisper-large-v3-turbo`, faster-whisper large-v3-turbo
pinned to one Hub revision), loaded offline with `local_files_only`. Only when
`MODEL_ROOT` is unset or `readiness.json` doesn't report that alias ready does
the command fall back to `large-v3-turbo` from
`${XDG_CACHE_HOME:-~/.cache}/faster-whisper`, downloading it on first use, and
it says so on stderr. Report that fallback rather than letting the cache
become a second copy: ask for `systemctl --user start local-models-sync.service`
on the host. `--model` accepts another faster-whisper model name or a local
CTranslate2 model directory, which skips the catalog. Cached weights are files,
not a resident model. Use `--language en` or another code
when known, otherwise allow automatic detection. No transcription API key is
needed and audio stays local.

The command writes `transcript.txt`, `transcript.json` and `transcript.srt`.
Use those timestamps when quoting audio. Note uncertain wording rather than
inventing speech. These are speech transcripts, not speaker diarization.
Report output paths and any partial failure; a failed run can leave partial
outputs, so retry into a fresh directory. Keep the command in the foreground
until completion, and follow shared media storage rules afterward.
