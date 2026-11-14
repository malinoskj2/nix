# Research behind the local collector

Reviewed 2026-11-14. These are public implementations, not knowledge of
ScrapeCreators' private infrastructure.

- [TikTok-Api search](https://github.com/davidteather/TikTok-Api/blob/main/TikTokApi/api/search.py)
  uses browser-backed requests, carries cursor/search ID, and warns that video
  search requires authentication. There is no documented public `search.videos`.
- [Captured web requests](https://github.com/cv-cat/TiktokApis/blob/master/api/tiktok_web.py)
  identify `/api/search/general/full/` with keyword, cursor/offset and session
  parameters. Observing the browser avoids maintaining a separate signing stack.
- [ScrapeCreators keyword contract](https://docs.scrapecreators.com/v1/tiktok/search/keyword/openapi.json)
  offers relative date buckets, relevance/likes/date sorting and cursors, with
  duplicates possible. Its proxy region does not filter creator origin.
- [Official Research API](https://developers.tiktok.com/docs/en/research-api-specs-query-videos)
  provides date queries and pagination but requires approved research access.

Current collector limitations: local exact-date filtering only; ordinary search
ranking and availability; no globally exhaustive result set; browser/session
requirements can change. A login wall or blocked request must be reported rather
than interpreted as zero matching videos. No signature reverse engineering,
proxy rotation, challenge solving, paid service or inference model is involved.

Live sandbox check on this date reached TikTok but displayed “Log in to search
for popular content.” Only `/api/search/user/preview/` returned, which is not a
video result and is excluded. Authenticated live video collection remains
unverified. Offline Chromium tests cover video pagination, deduplication,
repeated-page stopping, HTTP denial, login walls and unsupported responses.
