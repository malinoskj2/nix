"""Offline response handling regression tests; no YouTube requests."""

import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

import search_shorts as collector


class Response(io.BytesIO):
    code = 200
    headers = {"Content-Type": "text/html"}

    def geturl(self):
        return "https://www.youtube.com/results?search_query=test"


class SearchTests(unittest.TestCase):
    def test_success_keeps_only_unique_short_ids(self):
        renderer = {"reelItemRenderer": {"videoId": "abcdefghijk"}}
        data = {"twoColumnSearchResultsRenderer": [renderer, renderer, {"videoRenderer": {"videoId": "lmnopqrstuv"}}]}
        page = ("var ytInitialData = " + json.dumps(data) + ";").encode()
        with patch.object(collector, "urlopen", return_value=Response(page)):
            report = collector.search("test")
        self.assertEqual([v["id"] for v in report["videos"]], ["abcdefghijk"])
        self.assertEqual(report["coverage"]["scope"], "first_page_only")

    def test_unknown_page_is_not_reported_as_access_denial(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(collector, "urlopen", return_value=Response(b"<html>Changed page</html>")):
                with self.assertRaises(collector.SearchFailure) as raised:
                    collector.search("test", folder)
            self.assertEqual(raised.exception.kind, "missing_search_data")
            self.assertEqual(json.loads((Path(folder) / "response.json").read_text())["status"], 200)
            self.assertIn("Changed page", (Path(folder) / "response.html").read_text())

    def test_http_failure_preserves_body_and_retry_after(self):
        error = HTTPError(
            "https://www.youtube.com/results",
            429,
            "Too Many Requests",
            {"Retry-After": "120"},
            io.BytesIO(b"rate limit"),
        )
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(collector, "urlopen", side_effect=error):
                with self.assertRaises(collector.SearchFailure) as raised:
                    collector.search("test", folder)
            self.assertEqual(raised.exception.kind, "rate_limited")
            metadata = json.loads((Path(folder) / "response.json").read_text())
            self.assertEqual(metadata["retry_after"], "120")
            self.assertEqual((Path(folder) / "response.html").read_text(), "rate limit")

    def test_parser_failures_remain_distinct(self):
        for page, expected in [
            (b"var ytInitialData = invalid;", "invalid_search_data"),
            (b"var ytInitialData = {};", "layout_changed"),
            (b'var ytInitialData = {"twoColumnSearchResultsRenderer": {}};', "no_short_renderers"),
        ]:
            with self.subTest(expected=expected), patch.object(collector, "urlopen", return_value=Response(page)):
                with self.assertRaises(collector.SearchFailure) as raised:
                    collector.search("test")
                self.assertEqual(raised.exception.kind, expected)

    def test_distinct_failure_classes(self):
        for status, url, html, expected in [
            (403, "https://www.youtube.com", "", "access_denied"),
            (200, "https://consent.youtube.com/", "", "consent_required"),
            (200, "https://www.youtube.com", "unusual traffic from your computer network", "bot_challenge"),
            (503, "https://www.youtube.com", "", "http_error"),
        ]:
            with self.subTest(expected=expected), self.assertRaises(collector.SearchFailure) as raised:
                collector.classify_response(status, url, html)
            self.assertEqual(raised.exception.kind, expected)


if __name__ == "__main__":
    unittest.main()
