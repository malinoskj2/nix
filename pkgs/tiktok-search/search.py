"""Collect TikTok's normal browser search responses; never replay signed requests."""

import argparse
import json
import os
import shutil
import time as clock
from datetime import UTC, date, datetime, time, timedelta
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse


def number(value):
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return None


def videos(payload):
    """Search returns mixed cards; only accept objects with video identity/data."""
    if isinstance(payload, list):
        for value in payload:
            yield from videos(value)
    elif isinstance(payload, dict):
        identity = str(payload.get("id", payload.get("aweme_id", "")))
        author = payload.get("author", {})
        if identity.isdigit() and isinstance(author, dict) and "video" in payload:
            handle = author.get("uniqueId", author.get("unique_id"))
            created = number(payload.get("createTime", payload.get("create_time")))
            if handle and created:
                stats = payload.get("stats") or payload.get("statistics") or {}
                try:
                    published = datetime.fromtimestamp(created, UTC).isoformat()
                except (OverflowError, OSError, ValueError):
                    return
                yield {
                    "id": identity,
                    "url": f"https://www.tiktok.com/@{quote(str(handle), safe='')}/video/{identity}",
                    "creator": handle,
                    "description": payload.get("desc", ""),
                    "created_at": published,
                    "created_timestamp": created,
                    "views": number(stats.get("playCount", stats.get("play_count"))),
                    "likes": number(stats.get("diggCount", stats.get("digg_count"))),
                    "comments": number(stats.get("commentCount", stats.get("comment_count"))),
                    "shares": number(stats.get("shareCount", stats.get("share_count"))),
                }
                return
        for value in payload.values():
            if isinstance(value, (dict, list)):
                yield from videos(value)


def select(items, start, end, min_views, min_likes, sort):
    return sorted(
        (
            item
            for item in items
            if start <= item["created_timestamp"] < end
            and (not min_views or (item["views"] is not None and item["views"] >= min_views))
            and (not min_likes or (item["likes"] is not None and item["likes"] >= min_likes))
        ),
        key=lambda item: (item[sort] if item[sort] is not None else -1, item["id"]),
        reverse=True,
    )


def search_response(url, query):
    parsed = urlparse(url)
    return (
        parsed.hostname in ("www.tiktok.com", "www.tiktok.com.")
        and parsed.path in ("/api/search/general/full/", "/api/search/item/full/")
        and parse_qs(parsed.query).get("keyword") == [query]
    )


def collect(args):
    from playwright.sync_api import sync_playwright

    found = {}
    pages = 0
    reason = None
    errors = []
    exhausted = False
    seen_batches = set()
    started = clock.monotonic()

    def response_received(response):
        nonlocal pages, reason, exhausted
        if reason or pages >= args.max_pages or not search_response(response.url, args.query):
            return
        if response.status in (401, 403, 429):
            reason = f"http_{response.status}"
            return
        if response.status != 200:
            reason = "search_http_error"
            return
        try:
            payload = response.json()
            if not isinstance(payload, dict):
                raise TypeError("unexpected search response")
            if payload.get("status_code", 0) != 0:
                reason = "search_api_error"
                return
            result_lists = [payload[key] for key in ("data", "item_list", "search_item_list") if key in payload]
            if not result_lists or any(not isinstance(value, list) for value in result_lists):
                reason = "unsupported_search_response"
                return
            batch = list(videos(payload))
            if any(result_lists) and not batch:
                reason = "no_video_records"
                return
        except Exception:  # noqa: BLE001 - browser payload failures must preserve prior results
            reason = "invalid_search_response"
            return
        pages += 1
        signature = tuple(item["id"] for item in batch)
        if signature and signature in seen_batches:
            reason = "repeated_page"
            return
        seen_batches.add(signature)
        for item in batch:
            if len(found) >= args.max_videos:
                break
            found[item["id"]] = item
        exhausted = payload.get("has_more") in (False, 0, "0")

    with sync_playwright() as playwright:
        profile = Path(args.profile).expanduser()
        profile.mkdir(parents=True, exist_ok=True, mode=0o700)
        context = playwright.chromium.launch_persistent_context(
            str(profile),
            executable_path=shutil.which(os.environ.get("TIKTOK_CHROMIUM", "chromium")),
            headless=not args.headed,
            chromium_sandbox=not args.no_sandbox,
            viewport={"width": 1280, "height": 900},
            locale="en-US",
        )
        try:
            page = context.pages[0] if context.pages else context.new_page()
            page.on("response", response_received)
            navigation = page.goto(
                "https://www.tiktok.com/search?q=" + quote(args.query, safe=""),
                wait_until="domcontentloaded",
                timeout=min(30000, args.timeout * 1000),
            )
            if navigation and navigation.status >= 400:
                reason = f"navigation_http_{navigation.status}"
            idle = 0
            while not reason and clock.monotonic() - started < args.timeout:
                before = (len(found), pages)
                page.wait_for_timeout(2000)
                # Stop for a human; never attempt to solve a verification challenge.
                if page.locator('iframe[src*="captcha"], [id*="captcha-verify"]').count():
                    reason = "verification_required"
                    break
                if "/login" in page.url or page.get_by_text("Log in to search", exact=False).count():
                    reason = "login_required"
                    break
                if exhausted:
                    reason = "search_exhausted"
                    break
                if pages >= args.max_pages or len(found) >= args.max_videos:
                    reason = "collection_limit"
                    break
                idle = idle + 1 if before == (len(found), pages) else 0
                if idle >= 5:
                    reason = "no_more_responses" if pages else "no_search_responses"
                    break
                page.mouse.wheel(0, 1800)
            reason = reason or "time_limit"
        except Exception as exc:  # noqa: BLE001 - report partial results without leaking signed URLs
            # Exception text can include signed URLs. Keep secrets out of output.
            errors.append(type(exc).__name__)
            reason = "browser_error"
        finally:
            context.close()
    return list(found.values()), pages, reason, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("query")
    parser.add_argument("--since", type=date.fromisoformat, required=True)
    parser.add_argument("--until", type=date.fromisoformat, required=True, help="inclusive UTC calendar date")
    parser.add_argument("--min-views", type=int, default=0)
    parser.add_argument("--min-likes", type=int, default=0)
    parser.add_argument("--sort", choices=("views", "likes", "created_timestamp"), default="views")
    parser.add_argument("--max-pages", type=int, default=10)
    parser.add_argument("--max-videos", type=int, default=200)
    parser.add_argument("--timeout", type=int, default=90, help="total collection seconds")
    parser.add_argument("--headed", action="store_true")
    parser.add_argument("--no-sandbox", action="store_true", help="only for the agent container")
    parser.add_argument(
        "--profile",
        default=str(Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "tiktok-search/browser"),
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    if (
        not args.query.strip()
        or args.until < args.since
        or args.until == date.max
        or min(args.min_views, args.min_likes) < 0
        or not 1 <= args.max_pages <= 100
        or not 1 <= args.max_videos <= 2000
        or not 10 <= args.timeout <= 600
    ):
        parser.error("invalid query/date/threshold or bounds (pages 1–100, videos 1–2000, timeout 10–600)")
    if args.output_dir.exists():
        parser.error("output directory already exists; choose a fresh path")
    start = datetime.combine(args.since, time.min, UTC).timestamp()
    end = datetime.combine(args.until + timedelta(days=1), time.min, UTC).timestamp()
    args.output_dir.mkdir(parents=True)
    try:
        items, pages, reason, errors = collect(args)
    except Exception as exc:  # noqa: BLE001 - report partial results without leaking signed URLs
        items, pages, reason, errors = [], 0, "browser_start_failed", [type(exc).__name__]
    selected = select(items, start, end, args.min_views, args.min_likes, args.sort)
    report = {
        "query": args.query,
        "collected_at": datetime.now(UTC).isoformat(),
        "filters": {
            "since": str(args.since),
            "until": str(args.until),
            "timezone": "UTC",
            "min_views": args.min_views,
            "min_likes": args.min_likes,
            "sort": args.sort,
        },
        "coverage": {
            "exhaustive": False,
            "stop_reason": reason,
            "responses": pages,
            "collected_videos": len(items),
            "matching_videos": len(selected),
            "errors": errors,
            "note": "Filtered browser-ranked results; not all TikTok videos or global popularity leaders.",
        },
        "videos": selected,
    }
    (args.output_dir / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    (args.output_dir / "links.txt").write_text("".join(item["url"] + "\n" for item in selected))
    print(json.dumps(report, indent=2))
    return (
        0
        if pages
        and reason in ("search_exhausted", "collection_limit", "no_more_responses", "time_limit", "repeated_page")
        else 2
    )


if __name__ == "__main__":
    raise SystemExit(main())
