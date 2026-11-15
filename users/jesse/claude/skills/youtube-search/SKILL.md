---
name: youtube-search
description: Search YouTube for videos, Shorts, creators, tutorials or recent discussion. Supports native Shorts-only search and general research with last30days. Use for discovery; use video-download for saving a known video and audio-transcribe for local speech recognition.
---

# YouTube search

For Shorts-only requests, use the workflow below. For general video research,
use `last30days`; do not impose a Shorts filter unless requested.

## Shorts-only search

Use the bundled collector, which requests YouTube's native Shorts search filter
and reads only Shorts renderers from the returned page. Duration, portrait
dimensions, `#shorts`, and adding “shorts” to a query are not proof of YouTube's
classification. The installed yt-dlp can miss these search renderers, while
`last30days` normalizes links to `/watch` and loses the Shorts marker.

Resolve `skill_dir` to this skill's directory. Create a fresh `output_dir` under
the repository's `.tmp/youtube-search/`, then run:

```sh
python3 "$skill_dir/scripts/search_shorts.py" "USER SEARCH TERMS" \
  > "$output_dir/shorts.json" 2> "$output_dir/search.log"
```

Check the exit status and search.log. `shorts.json` contains a `videos` list
with titles, Shorts URLs and view-count labels when available, plus `coverage`.
The collector reads only the first results page, without pagination. Use a few
focused query variants if needed, deduplicating by ID. Do not describe these
results as exhaustive or globally most popular. Missing fields mean unknown;
view-count labels are approximate, not exact engagement counts.
For a known creator, yt-dlp can also list their channel's `/shorts` URL using
`--flat-playlist --dump-json --playlist-end 100`.

Search entries lack exact upload dates and may lack creator and engagement
data. When the user specifies a time window, fetch metadata for the retained URLs with yt-dlp
`--ignore-config --no-cookies-from-browser --skip-download --dump-json` (without
`--flat-playlist`), then filter `upload_date` against inclusive requested dates.
Use bounded batches with `--socket-timeout 20 --retries 1 --extractor-retries 1`. Preserve the original
Shorts URLs by ID: full metadata may normalize them to `/watch`.
Exclude undated entries from confirmed date matches and disclose them as
unverified. Without a requested window this path searches all dates; state that
scope. Do not imply last30days' default 30-day window was applied here.

Report blocked or partial searches and metadata failures explicitly; an empty
filtered list does not prove there are no matching Shorts. Stop on access
failures rather than retrying repeatedly. Search and metadata extraction do not
download media; use video-download only when asked to save videos.

## General video research

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
