import unittest

from search import search_response, select, videos


class SearchTest(unittest.TestCase):
    def test_mixed_payloads(self):
        payload = {
            "data": [
                {
                    "item": {
                        "id": "123",
                        "author": {"uniqueId": "a"},
                        "video": {},
                        "createTime": 100,
                        "stats": {"playCount": 200},
                    }
                },
                {
                    "aweme_info": {
                        "aweme_id": "456",
                        "author": {"unique_id": "b"},
                        "video": {},
                        "create_time": 200,
                        "statistics": {"digg_count": 20},
                    }
                },
                {"id": "999", "author": {"uniqueId": "user-card"}},
            ]
        }
        items = list(videos(payload))
        self.assertEqual([item["id"] for item in items], ["123", "456"])
        self.assertIsNone(items[1]["views"])
        self.assertEqual(items[0]["url"], "https://www.tiktok.com/@a/video/123")

    def test_exact_dates_and_unknown_metrics(self):
        items = [
            {"id": str(t), "created_timestamp": t, "views": views, "likes": 5}
            for t, views in [(99, 1000), (100, 10), (150, None), (199, 20), (200, 1000)]
        ]
        self.assertEqual([v["id"] for v in select(items, 100, 200, 0, 0, "views")], ["199", "100", "150"])
        self.assertEqual([v["id"] for v in select(items, 100, 200, 15, 0, "views")], ["199"])

    def test_only_current_query_search_responses(self):
        self.assertFalse(search_response("https://www.tiktok.com/api/search/user/preview/?keyword=cat", "cat"))
        self.assertTrue(search_response("https://www.tiktok.com/api/search/general/full/?keyword=cat+food", "cat food"))
        self.assertFalse(search_response("https://www.tiktok.com/api/search/general/full/?keyword=dog", "cat food"))
        self.assertFalse(search_response("https://evil.test/api/search/general/full/?keyword=cat", "cat"))
        self.assertFalse(search_response("https://www.tiktok.com/api/search/suggest/?keyword=cat", "cat"))


if __name__ == "__main__":
    unittest.main()
