---
name: youtube-search
description: Search YouTube for videos, creators, tutorials or recent discussion using the last30days CLI. Use for discovery; use video-download for saving a known video and audio-transcribe for local speech recognition.
---

# YouTube search

Use the Nix-installed `last30days` command, restricted to YouTube. It uses
`yt-dlp` without a YouTube API key. The engine defaults to the last 30 days;
set `--days N` to match the requested time window and disclose that window.

Create a fresh output directory under the repository's `.tmp/youtube-search/`.
Generate a query plan with the user's actual query and one or two useful angles;
every subquery must specify only `youtube`. Pass JSON on stdin with a quoted
heredoc; do not interpolate shell variables into the JSON.

```sh
LAST30DAYS_YOUTUBE_BACKEND=yt-dlp last30days --research-only \
  --search youtube --no-browser-cookies --emit json --quick \
  --save-dir "$output_dir" --plan - "USER TOPIC" <<'PLAN'
{
  "intent": "how_to",
  "freshness_mode": "evergreen_ok",
  "cluster_mode": "workflow",
  "subqueries": [
    {
      "search_query": "USER SEARCH TERMS",
      "ranking_query": "THE USER'S ACTUAL QUESTION",
      "sources": ["youtube"],
      "weight": 1.0
    }
  ]
}
PLAN
```

Choose intent and wording for the request rather than copying the example's
`how_to` unconditionally. Omit `--quick` when deeper coverage is warranted.
Use `strict_recent` for time-sensitive requests and report any older evergreen
results outside the requested window.
The backend pin keeps this YouTube workflow on yt-dlp even if paid search keys
are configured for other platforms.

Return useful video titles, creators, direct URLs and any available dates or
engagement figures. Distinguish metadata or captions from verified video content.
Inspect source outcomes in the result: a blocked, partial or failed search is
not evidence that no matching videos exist. Do not download videos unless asked.
