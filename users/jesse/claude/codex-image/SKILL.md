---
name: codex-image
description: Generate or edit raster images with Codex (gpt-6-astra, high reasoning) and its built-in image generator. Use whenever a task needs a raster or visually complex image that can't reasonably be hand-written as SVG, CSS or code, such as illustrations, photos, realistic or painterly art, detailed icons, logos with texture, sprites, textures, backgrounds, hero images, mockups, concept art, reference images for 3D, or edits to an existing image. Don't use it for charts, diagrams, simple geometric SVG, screenshots or UI you can build in code.
---

# Codex image generation

Generating an image takes about a minute. Batch related images into one call when they can share a prompt.

## Generate

```sh
out=$(mktemp -d)
codex exec \
  -m gpt-6-astra \
  -c model_reasoning_effort=high \
  -s read-only \
  --skip-git-repo-check \
  -C "$out" \
  -o "$out/last.txt" \
  'Use $imagegen to generate <description>. Don'\''t run shell commands. Reply with only the absolute path of each generated image, one per line.' \
  </dev/null
cat "$out/last.txt"
```

- Run it with a Bash timeout of 600000 ms.
- Keep `-s read-only` and the no-shell instruction. Codex's own sandbox can't start in some containers, so Codex only generates and you copy the file.
- Images land under `~/.codex/generated_images/<thread>/`. Copy them to where the task needs them; never link to that directory from a project.
- For edits or style references, attach the images with `-i a.png,b.png` and say in the prompt what to change and what to keep.
- The prompt should describe subject, style, composition, palette, aspect ratio and whether the background must be transparent. Codex returns its own size, so resize or crop afterwards when an exact size matters.

## Check

Read each image before using it. If it misses the brief, run again with a prompt that names what was wrong. Report the final path of each image you kept.
