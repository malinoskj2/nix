---
name: tiktok-search
description: Search TikTok for videos, creators, trends or recent discussion using the last30days CLI and ScrapeCreators. Use for discovery; use video-download to save a known TikTok video.
---

# TikTok search

Use the Nix-installed `last30days` command with `--search tiktok`. TikTok search
requires `SCRAPECREATORS_API_KEY`, supplied through the process environment or
`~/.config/last30days/.env`. The sandbox mounts an existing host `.env` at that
same location when it starts. Keep keys out of chat, command arguments and Nix
source. If the source is unconfigured, report the missing key rather than
presenting it as an empty search. Requests consume the provider's credits.

Create a fresh output directory under the repository's `.tmp/tiktok-search/`.
Generate one or two focused queries and pass a plan on stdin. Restrict every
subquery to TikTok; no other platform is a substitute for TikTok results.

```sh
last30days --research-only --search tiktok --no-browser-cookies \
  --emit json --quick --save-dir "$output_dir" --plan - "USER TOPIC" <<'PLAN'
{
  "intent": "concept",
  "freshness_mode": "strict_recent",
  "cluster_mode": "none",
  "subqueries": [
    {
      "search_query": "USER SEARCH TERMS",
      "ranking_query": "THE USER'S ACTUAL QUESTION",
      "sources": ["tiktok"],
      "weight": 1.0
    }
  ]
}
PLAN
```

Adapt the plan to the request. Set `--days N` for the requested date window
(default 30), and omit `--quick` for deeper coverage. Use `--tiktok-hashtags`
or `--tiktok-creators` when the user identifies those targets.

Report titles/captions, creators, direct video URLs and available dates and
engagement. Inspect source outcomes and explain failures or partial coverage.
Do not claim to have watched a video based only on its metadata, or download
videos unless requested.
