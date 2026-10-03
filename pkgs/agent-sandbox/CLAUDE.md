# Sandbox

You are running inside a Docker sandbox. You may read anything you can find in the container, including the directories mapped from the host:

- `~/projects`, `~/nix` and `~/orca/workspaces` (Orca's worktrees), read-write, at the same paths as on the host
- `/tmp/screenshot`, read-only: the human's screenshots
- `/tmp/agent-media`, read-write: the screenshots and recordings you take, at the same path as on the host
- `~/.cache/img2char3d`, read-write: model weights for `~/projects/img2char3d`
- `~/.claude/projects`, read-write: auto-memory and session transcripts, shared with the human's sessions outside the sandbox
- `/nix/store`, read-only, shared with the host

The rest of the home directory belongs to the sandbox, not the host. The NVIDIA GPU is available (`nvidia-smi`).

## Display

A headless sway Wayland session runs on `$WAYLAND_DISPLAY` with a single 1280x800 output, `HEADLESS-1`. Xwayland is enabled for X11-only apps. The human can watch it over VNC. `$XDG_RUNTIME_DIR/renderer` names the renderer sway started with, and its logs are in `$XDG_RUNTIME_DIR/logs`.

If the display doesn't work, tell the user straight away instead of working around it: that includes `$XDG_RUNTIME_DIR/renderer` missing, `swaymsg` or `grim` failing, or an app failing to open a window. Also mention it if the renderer is `pixman`, which means the GPU renderer failed and the display is rendered on the CPU. Include the relevant lines from `$XDG_RUNTIME_DIR/logs`.

- Launch an app: `swaymsg exec -- <command>`
- Screenshot: `grim /tmp/agent-media/screen.png`, then read the image. Coordinates in the image are output pixels.
- Region screenshot: `grim -g "X,Y WxH" /tmp/agent-media/region.png`
- Windows and geometry: `swaymsg -t get_tree`
- Move the pointer: `swaymsg seat - cursor set X Y`
- Click: `swaymsg seat - cursor press button1` then `swaymsg seat - cursor release button1`
- Scroll: `wlrctl pointer scroll DY DX`
- Type text: `wtype 'text'`; keys: `wtype -k Return`, chords: `wtype -M ctrl -k l -m ctrl`

### Nested Hyprland

A second headless sway, kept off `$WAYLAND_DISPLAY` and `$SWAYSOCK`, hosts a persistent Hyprland: the host desktop's pinned version, restarted whenever it exits. It draws to its own 1920x1080 output, `NESTED-1`, the size of the desktop's main monitor, and the human can watch and drive it over a second VNC port. It loads the desktop's `look.lua` from `/run/host-hypr`, so blur, layer rules, animations and plugins (hyprfocus, hyprbars, hyprglass) match the desktop's; the display also uses the desktop's fonts, fontconfig settings, desktop entries, icon themes and time zone database. Its cursor hides 0.1 s after the pointer stops, because a headless output draws the cursor into screenshots and the desktop's screenshots never show it. Use it to try Hyprland configs, plugins and j2bar before they reach the host.

- Clients: set `WAYLAND_DISPLAY=hyprland-1`, e.g. `WAYLAND_DISPLAY=hyprland-1 foot &`
- Screenshot: `WAYLAND_DISPLAY=hyprland-1 grim -o NESTED-1 /tmp/agent-media/hypr.png`
- Control it with `hyprctl`, which finds the instance on its own: `hyprctl monitors`, `hyprctl dispatch ...`, `hyprctl plugin load <path>`, `hyprctl reload`
- Its logs are `hyprland.log`, `nested-sway.log` and `wayvnc-hyprland.log` in `$XDG_RUNTIME_DIR/logs`. If it keeps crashing, `hyprland-restarts.log` there grows.

Don't delete sockets or lock files in `$XDG_RUNTIME_DIR`: the sway and Hyprland sessions only create them at startup, so removing one cuts off every new client until the sandbox restarts.

## Tools

Orca's CLI is `orca-ide`, which forwards to `~/.orca-relay/bin/orca`, the SSH bridge to the running desktop. If an older sandbox lacks `orca-ide`, use `~/.orca-relay/bin/orca` directly. Do not launch an Orca Electron binary from `/nix/store` for CLI commands. Worktree cleanup must target only the requested worktree, including its Orca state when managed by Orca.

Blender (Cycles with CUDA and OptiX) and a Python with torch (CUDA) and hy3dgen (Hunyuan3D) are installed; `~/projects/img2char3d` runs directly on them. Chromium is installed with its own sandbox off, since the container can't run it: open pages on the display with `swaymsg exec -- chromium <url>`, or render one without a window with `chromium --headless --screenshot=<file> --window-size=W,H <url>`. The Playwright MCP server drives its own Chromium, shown on the display, and the `playwright` CLI is installed. Nix talks to the host daemon. Get a missing tool with `nix shell nixpkgs#<package>` or `nix run nixpkgs#<package>`.

All sandboxes share a 20G memory limit; past it the kernel kills the largest process. Run one cargo build or test at a time, including across subagents and separate target dirs. Each one already uses every core, and several at once fill the limit with linkers.

Cargo compiles through sccache, whose cache at `~/.cache/sccache` every sandbox shares, so a new worktree reuses the dependency crates another one already built. Don't delete it as scratch.

## Disk

`~/projects` is on the host's disk, so anything you leave behind stays there.

- When a task finishes, delete the target dirs, worktrees, venvs, databases and other scratch you created for it. Leave only what the human needs to keep working.
- Before finishing, check what you added with `du -sh` and report anything over a few GB that you kept.
