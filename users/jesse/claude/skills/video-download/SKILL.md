---
name: video-download
description: Download YouTube or TikTok videos, or extract their audio, using the Nix-installed yt-dlp and FFmpeg. Use when the user asks to save media from a URL; discovery belongs to youtube-search or tiktok-search.
---

# Video download

Use `yt-dlp` from PATH. Nix supplies FFmpeg and yt-dlp's JavaScript runtime;
do not install packages with pip or run yt-dlp's self-updater.

Create a fresh directory under the repository's `.tmp/video-download/` and use
the exact requested URLs. A single-video request should not expand into a
playlist or creator archive.

```sh
yt-dlp --ignore-config --no-playlist --no-overwrites --write-info-json \
  --paths "$output_dir" -o '%(extractor_key)s-%(id)s-%(title).160B.%(ext)s' \
  --print after_move:filepath -- "$url"
```

The same command handles YouTube, Shorts and TikTok video URLs. Select quality
or format when the user specifies it. For audio-only requests add
`--extract-audio`; preserve the native audio format unless conversion is needed.
Use the explicit playlist options only for a requested batch, keeping its scope
bounded to what was requested.

On access, cookie, challenge or rate-limit failures, report the actual error.
Use browser cookies only when the user has authorized that access. Do not
silently switch accounts, downloaders or paid services.

Report each saved file's absolute host path. Use `audio-transcribe` if a
transcript was requested. Follow the shared asset-storage rule once the files
are no longer actively used; preserve original media when archiving.
