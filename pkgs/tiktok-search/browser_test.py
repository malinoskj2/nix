"""Offline browser integration checks; run with the package Python/Playwright environment."""

import contextlib
import json
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

from playwright.sync_api import sync_playwright
from search import collect


@contextlib.contextmanager
def fixture_browser(payloads):
    with sync_playwright() as p:
        original = p.chromium.launch_persistent_context

        def launch(*a, **kw):
            context = original(*a, **kw)
            sequence = iter(payloads)
            last = payloads[-1]

            def route(r):
                nonlocal last
                if "/api/search/general/full/" in r.request.url:
                    last = next(sequence, last)
                    r.fulfill(status=last[0], content_type="application/json", body=json.dumps(last[1]))
                elif "/search?" in r.request.url and payloads[0][1].get("login"):
                    r.fulfill(content_type="text/html", body="<p>Log in to search for popular content</p>")
                elif "/search?" in r.request.url:
                    r.fulfill(
                        content_type="text/html",
                        body="""<body style="height:20000px"><script>
                    function get(){fetch('/api/search/general/full/?keyword=test')}
                    get(); addEventListener('wheel',get);
                    </script></body>""",
                    )
                else:
                    r.abort()

            context.route("**/*", route)
            return context

        with patch.object(p.chromium, "launch_persistent_context", launch):
            yield p


def item(i):
    return {
        "id": str(i),
        "author": {"uniqueId": "fixture"},
        "createTime": 100,
        "video": {},
        "stats": {"playCount": 500},
    }


cases = [
    (
        [(200, {"data": [item(1)], "has_more": 1}), (200, {"data": [item(1), item(2)], "has_more": 0})],
        2,
        "search_exhausted",
    ),
    ([(200, {"data": [item(1)], "has_more": 1})], 1, "repeated_page"),
    ([(403, {})], 0, "http_403"),
    ([(200, {"login": True})], 0, "login_required"),
    ([(200, {"unexpected": []})], 0, "unsupported_search_response"),
]
for payloads, count, reason in cases:
    with tempfile.TemporaryDirectory(prefix="tiktok-fixture-") as profile:
        args = SimpleNamespace(
            query="test", profile=profile, headed=False, no_sandbox=True, max_pages=5, max_videos=10, timeout=30
        )
        with patch("playwright.sync_api.sync_playwright", lambda payloads=payloads: fixture_browser(payloads)):
            found, pages, stop, errors = collect(args)
        assert (len(found), stop, errors) == (count, reason, []), (found, pages, stop, errors)
        print("PASS", reason, flush=True)
