"""Search the first page of YouTube's Shorts-only results, without downloading media."""

import argparse
import json
import re
import sys
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)


def extract_shorts(data):
    seen = set()
    for obj in objects(data):
        renderer = obj.get("shortsLockupViewModel") or obj.get("reelItemRenderer")
        if not isinstance(renderer, dict):
            continue
        video_id = renderer.get("videoId")
        for child in objects(renderer):
            endpoint = child.get("reelWatchEndpoint", {})
            if endpoint.get("videoId"):
                video_id = endpoint["videoId"]
                break
        if not isinstance(video_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{11}", video_id):
            continue
        if video_id in seen:
            continue
        seen.add(video_id)
        overlay = renderer.get("overlayMetadata", {})
        title = overlay.get("primaryText", {}).get("content")
        if not title:
            text = renderer.get("headline", {})
            title = text.get("simpleText") or "".join(run.get("text", "") for run in text.get("runs", []))
        yield {
            "id": video_id,
            "url": f"https://www.youtube.com/shorts/{video_id}",
            "title": title or None,
            "views_label": overlay.get("secondaryText", {}).get("content"),
        }


def search(query):
    # YouTube's Type > Shorts filter, as emitted by its searchFilterRenderer.
    url = "https://www.youtube.com/results?" + urlencode({"search_query": query, "sp": "EgIQCQ%3D%3D", "hl": "en"})
    request = Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept-Language": "en-US,en;q=0.9"})
    with urlopen(request, timeout=30) as response:
        page = response.read(8_000_001)
    if len(page) > 8_000_000:
        raise ValueError("Search page exceeded the 8 MB limit")
    html = page.decode("utf-8")
    marker = re.search(r"(?:var\s+)?ytInitialData\s*=\s*", html)
    if not marker:
        raise ValueError("YouTube returned no search data (possibly blocked or a consent page)")
    data, _ = json.JSONDecoder().raw_decode(html[marker.end() :])
    if not any("twoColumnSearchResultsRenderer" in obj for obj in objects(data)):
        raise ValueError("YouTube search layout missing; cannot confirm search results")
    videos = list(extract_shorts(data))
    if not videos:
        raise ValueError("No Shorts renderers found; empty results or a changed layout, not confirmed absence")
    return {
        "query": query,
        "videos": videos,
        "coverage": {"scope": "first_page_only", "date_window": None, "count": len(videos), "search_url": url},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("query")
    args = parser.parse_args()
    try:
        report = search(args.query)
    except (OSError, ValueError) as error:
        print(f"Shorts search failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
