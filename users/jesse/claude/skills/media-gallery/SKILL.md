---
name: media-gallery
description: Present images and videos to the human in a live, mobile-friendly gallery with pinned "Needs review" and "New" sections and a full-screen swipe viewer. Use whenever you show the human three or more images or videos at once, ask them to look at or choose between renders, screenshots, recordings or generated media, or when they ask for a gallery. Also use for follow-up batches in the same task.
---

# Media gallery

`media-gallery` keeps a gallery in `<repo>/.tmp/gallery/` and serves it as a live page. The page polls every few seconds, so items you add, re-render or re-mark appear without a reload, highlighted. The human looks on their phone or desktop and replies in chat, referring to items by `#id`.

## Workflow

1. Save the media under the repo's `.tmp/` as usual.
2. Start a fresh gallery for a new task or batch. Skip this when adding to the gallery you're already using:
   `media-gallery init --title "<what this batch is>"`
3. Add items. Each file gets a stable `#id`.
   - `--review` for anything you need the human to look at or decide on. These go in the pinned **Needs review** section.
   - The default status is **new**: work worth seeing that doesn't need a decision.
   - `--done` for context, references or earlier accepted work.
   - `--section <name>` groups items by what they are (e.g. "Hero shots", "Walk cycle"); `--section-note` describes the group in one short sentence.
   - `--caption` is a short label; `--note` is the context for judging it: what changed, what to compare, the prompt or parameters.

   ```sh
   media-gallery add .tmp/hero-a.png .tmp/hero-b.png --review --section "Hero shots" \
     --caption "Warm grade" --note "B crops tighter; both at 1600x1200"
   media-gallery add .tmp/walk.mp4 --section "Walk cycle" --caption "Loop at 24 fps"
   ```
4. `media-gallery serve` starts the server in the background (or finds the running one) and prints the URL. Give the human that exact URL and say what you want from them, e.g. "#1 and #2 need a pick". Then end your turn.
5. When the human replies, map their `#id`s with `media-gallery list`.
6. After acting on their reply:
   - Re-render to the same path and `add` it again with `--review`. It keeps its id and shows as updated.
   - `media-gallery mark <ids> --done` once something is settled, so Needs review only holds open questions.
   - `media-gallery mark --all --done` before adding the next batch, so "New" means new since they last looked.

## Other commands

- `media-gallery list`: every item with its id, status and section.
- `media-gallery edit <id> --caption/--note/--section`, `media-gallery remove <ids>`.
- `media-gallery section <name> --note <text>`.
- `media-gallery url`, `media-gallery stop`.
- `--dir <path>` before the command uses another gallery directory, for a separate gallery in the same repo.

## Notes

- The server only serves files listed in the gallery, and the page is reachable from the LAN without a login, so don't add anything private.
- In the agent sandbox, `serve` uses a free preview port and prints its `$AGENT_PREVIEW_URL_*` link. On a host, it prints the host's LAN address.
- Browsers can't play every format. Prefer H.264 `.mp4` (`-pix_fmt yuv420p`) or `.webm` for video, and PNG, JPEG or WebP for images.
- Use the gallery instead of listing file paths. Still mention the files' absolute paths once if the human may want them on disk.
