---
name: tiktok-search
description: Find TikTok videos matching a query and date window, ranked or filtered by views and likes, returning links and metadata through our local browser collector. Use video-download to download selected videos afterward.
---

# TikTok search

Use the Nix-installed `tiktok-search` collector. It observes the ordinary TikTok
browser search responses, requires no ScrapeCreators key, and exits after each
run. Search does not download video files or transcribe audio.

Resolve the requested dates to inclusive UTC calendar dates. For “popular” with
no numerical threshold, rank by views and state that interpretation; don't
invent a minimum. Apply `--min-views` and/or `--min-likes` when specified.
Create a fresh output directory under the repository's `.tmp/tiktok-search/`.

```sh
tiktok-search "USER QUERY" --since YYYY-MM-DD --until YYYY-MM-DD \
  --sort views --max-pages 10 --max-videos 200 --timeout 90 \
  --output-dir "$output_dir"
```

In the agent sandbox, add `--no-sandbox` for the container's Chromium. For a
visible session add `--headed`, first following `sandbox-wayland-display` inside
the sandbox. The dedicated browser profile is at
`${XDG_STATE_HOME:-$HOME/.local/state}/tiktok-search/browser`; `--profile` can
select another dedicated profile. Never use a concurrently open browser profile
or copy cookies from the user's normal browser without their instruction.
Login or verification may require the human to open TikTok in that dedicated
profile and complete it themselves, then close the browser and retry:

```sh
chromium --user-data-dir="${XDG_STATE_HOME:-$HOME/.local/state}/tiktok-search/browser" \
  "https://www.tiktok.com/search?q=skateboarding"
```

Use the same host or sandbox as the collector, and add `--no-sandbox` in the
agent container. Never run the collector while that browser is open.
Do not solve challenges or
repeatedly retry blocked searches.

Read `results.json` and `links.txt`. Report captions, creators, posted dates,
views/likes and direct links, plus `coverage.stop_reason`, collected count and
matching count. Missing metrics mean unknown. Nonzero exit means failure or
interruption; partial results may still be saved. A successful empty search is
possible only when search responses were actually received.

The collector filters exact dates locally and ranks only what TikTok returned.
It does not push date or popularity filters to TikTok. Older or niche windows
can therefore have few matches even when matching videos exist. Never describe
these as *all* matching videos or the globally most popular: browser search is
ranked, session/region dependent, and not exhaustive even at search exhaustion.
For broader coverage, use a few focused query variants and deduplicate by video
ID; retain per-run coverage. Bounds can rise to 100 responses, 2,000 videos and
600 seconds, but stop on access failures. Do not claim to have watched videos
based on metadata. Use `video-download` only when downloads are requested.

`last30days --search tiktok` remains available as an explicitly selected paid
fallback requiring `SCRAPECREATORS_API_KEY` in the environment or
`~/.config/last30days/.env`. Do not silently spend credits when local search
fails. The implementation background and limitations are in
[references/research.md](references/research.md).
