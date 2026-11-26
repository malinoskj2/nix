"""Search the first page of YouTube's Shorts-only results, without downloading media."""

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
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


class SearchFailure(ValueError):
    def __init__(self, kind, message):
        self.kind = kind
        super().__init__(message)


def classify_response(status, final_url, html):
    if status == 429:
        raise SearchFailure("rate_limited", "HTTP 429; wait before further YouTube requests")
    if status in (401, 403):
        raise SearchFailure("access_denied", f"HTTP {status}; inspect the saved response")
    if urlsplit(final_url).hostname in ("consent.youtube.com", "consent.google.com"):
        raise SearchFailure("consent_required", "YouTube redirected to consent; resolve in a browser")
    if (
        "unusual traffic from your computer network" in html.lower()
        or "Our systems have detected unusual traffic" in html
    ):
        raise SearchFailure("bot_challenge", "YouTube returned a traffic challenge; resolve in a browser")
    if status >= 400:
        raise SearchFailure("http_error", f"HTTP {status}; inspect the saved response")


def search(query, diagnostics_dir=None):
    # YouTube's Type > Shorts filter, as emitted by its searchFilterRenderer.
    url = "https://www.youtube.com/results?" + urlencode({"search_query": query, "sp": "EgIQCQ%3D%3D", "hl": "en"})
    request = Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept-Language": "en-US,en;q=0.9"})
    try:
        response = urlopen(request, timeout=30)
    except HTTPError as error:
        response = error  # Preserve the error body and status for diagnosis.
    with response:
        status = response.code
        final_url = response.geturl()
        content_type = response.headers.get("Content-Type")
        retry_after = response.headers.get("Retry-After")
        page = response.read(8_000_001)
    html = page[:8_000_000].decode("utf-8", errors="replace")
    if diagnostics_dir is not None:
        destination = Path(diagnostics_dir)
        destination.mkdir(parents=True, exist_ok=True)
        (destination / "response.html").write_text(html, encoding="utf-8")
        (destination / "response.json").write_text(
            json.dumps(
                {
                    "status": status,
                    "final_url": final_url,
                    "content_type": content_type,
                    "retry_after": retry_after,
                    "bytes_read": len(page),
                    "truncated": len(page) > 8_000_000,
                },
                indent=2,
            ),
            encoding="utf-8",
        )
    classify_response(status, final_url, html)
    if len(page) > 8_000_000:
        raise SearchFailure("response_too_large", "Search page exceeded the 8 MB limit")
    marker = re.search(r"(?:var\s+)?ytInitialData\s*=\s*", html)
    if not marker:
        raise SearchFailure(
            "missing_search_data", "No ytInitialData found; cause unknown, inspect response diagnostics"
        )
    try:
        data, _ = json.JSONDecoder().raw_decode(html[marker.end() :])
    except ValueError as error:
        raise SearchFailure(
            "invalid_search_data", "Cannot decode ytInitialData; inspect response diagnostics"
        ) from error
    if not any("twoColumnSearchResultsRenderer" in obj for obj in objects(data)):
        raise SearchFailure("layout_changed", "YouTube search layout missing; cannot confirm search results")
    videos = list(extract_shorts(data))
    if not videos:
        raise SearchFailure("no_short_renderers", "Empty results or a changed layout; not confirmed absence")
    return {
        "query": query,
        "videos": videos,
        "coverage": {"scope": "first_page_only", "date_window": None, "count": len(videos), "search_url": url},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("query")
    parser.add_argument(
        "--diagnostics-dir", help="Save bounded response HTML and HTTP metadata here; use a fresh directory per query"
    )
    args = parser.parse_args()
    try:
        report = search(args.query, args.diagnostics_dir)
    except (OSError, ValueError) as error:
        kind = error.kind if isinstance(error, SearchFailure) else "network_or_io_error"
        print(f"Shorts search failed [{kind}]: {error}", file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
