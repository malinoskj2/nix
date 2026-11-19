---
name: media-gallery
description: Present images and videos to the human in a live, mobile-friendly gallery with pinned "Needs review" and "New" sections and a full-screen swipe viewer. Use whenever you show the human three or more images or videos at once, ask them to look at or choose between renders, screenshots, recordings or generated media, or when they ask for a gallery. Also use for follow-up batches in the same task.
---

# Media gallery

`media-gallery` keeps a gallery in `<repo>/.tmp/gallery/` and serves it as a live page. The page polls every few seconds, so items you add, re-render or re-mark appear without a reload, highlighted. The human looks on their phone or desktop and replies in chat, referring to items by `#id`.

## Workflow

1. Save the media under the repo's `.tmp/` as usual.
2. For a new task, start a fresh gallery: `media-gallery init --title "<the task>"`. Skip this for follow-up batches in the same task.
3. Publish each batch you show the human with one `batch` command and a JSON spec on stdin. Every item is checked before anything changes, so a missing file or unknown key fails the whole batch.

   ```sh
   media-gallery batch <<'EOF'
   {
     "title": "Hero shots, pass 2",
     "sections": {"Hero shots": "Warm grade at 1600x1200"},
     "items": [
       {"path": ".tmp/hero-a.png", "status": "review", "section": "Hero shots",
        "caption": "Tight crop", "note": "Cropped 10% closer than pass 1", "ask": "Which crop?"},
       {"path": ".tmp/hero-b.png", "status": "review", "section": "Hero shots",
        "caption": "Wide crop", "ask": "Which crop?"},
       {"path": ".tmp/walk.mp4", "section": "Walk cycle", "caption": "Loop at 24 fps"}
     ]
   }
   EOF
   ```

   - `title` names the batch and heads the page. `sections` sets notes shown under section headings.
   - `status`: `review` for anything the human must look at or decide on (the pinned **Needs review** section); `new` (the default) for work worth seeing without a decision; `done` for context or references.
   - `section` groups items by what they are; `caption` is a short label; `note` is the context for judging it: what changed, what to compare, the prompt or parameters.
   - `ask` is the question or request shown under the item in the grid and the viewer. Give every `review` item one, so the human knows what to judge.
   - A batch marks every earlier review and new item done, so the top of the page only holds the current batch. Earlier batches stay below as collapsed groups. Set `"keep": true` only when earlier questions are still open, such as when the human hasn't answered the previous batch yet.
   - Re-rendering to an earlier path keeps that item's `#id` and moves it into the new batch; its old batch links to it.
   - Paths are relative to the working directory. The command prints each item's `#id`.
4. `media-gallery serve` starts the server in the background (or finds the running one) and prints the URL. Give the human that exact URL and say what you want from them, e.g. "#1 and #2 need a pick". Then end your turn.
5. When the human replies, map their `#id`s with `media-gallery list`.
6. For a small fix within the current batch, such as one re-render, `media-gallery add <file> --review` (with `--caption`, `--note`, `--ask`, `--section`) adds to or refreshes it in the current batch without retiring anything. `media-gallery mark <ids> --done` settles items within a batch.

## Other commands

- `media-gallery list`: every item with its id, status, batch and section.
- `media-gallery edit <id> --caption/--note/--ask/--section`, `media-gallery remove <ids>`.
- `media-gallery section <name> --note <text>`.
- `media-gallery url`, `media-gallery stop`.
- `--dir <path>` before the command uses another gallery directory, for a separate gallery in the same repo.

## Notes

- The server only serves files listed in the gallery, and the page is reachable from the LAN without a login, so don't add anything private.
- In the agent sandbox, `serve` uses a free preview port and prints its `$AGENT_PREVIEW_URL_*` link. On a host, it prints the host's LAN address.
- Browsers can't play every format. Prefer H.264 `.mp4` (`-pix_fmt yuv420p`) or `.webm` for video, and PNG, JPEG or WebP for images.
- Every item has a download button in the grid and the viewer.
- Use the gallery instead of listing file paths. Still mention the files' absolute paths once if the human may want them on disk.
