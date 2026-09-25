# Sandbox

You are running inside a Docker sandbox. You may read anything you can find in the container, including the directories mapped from the host:

- `~/projects` and `~/nix`, read-write, at the same paths as on the host
- `/tmp/screenshot`, read-only: the human's screenshots
- `~/.cache/img2char3d`, read-write: model weights for `~/projects/img2char3d`
- `/nix/store`, read-only, shared with the host

The rest of the home directory belongs to the sandbox, not the host. The NVIDIA GPU is available (`nvidia-smi`).

## Display

A headless sway Wayland session runs on `$WAYLAND_DISPLAY` with a single 1280x800 output, `HEADLESS-1`. Xwayland is enabled for X11-only apps. The human can watch it over VNC. `$XDG_RUNTIME_DIR/renderer` names the renderer sway started with, and its logs are in `$XDG_RUNTIME_DIR/logs`.

If the display doesn't work, tell the user straight away instead of working around it: that includes `$XDG_RUNTIME_DIR/renderer` missing, `swaymsg` or `grim` failing, or an app failing to open a window. Also mention it if the renderer is `pixman`, which means the GPU renderer failed and the display is rendered on the CPU. Include the relevant lines from `$XDG_RUNTIME_DIR/logs`.

- Launch an app: `swaymsg exec -- <command>`
- Screenshot: `grim /tmp/screen.png`, then read the image. Coordinates in the image are output pixels.
- Region screenshot: `grim -g "X,Y WxH" /tmp/region.png`
- Windows and geometry: `swaymsg -t get_tree`
- Move the pointer: `swaymsg seat - cursor set X Y`
- Click: `swaymsg seat - cursor press button1` then `swaymsg seat - cursor release button1`
- Scroll: `wlrctl pointer scroll DY DX`
- Type text: `wtype 'text'`; keys: `wtype -k Return`, chords: `wtype -M ctrl -k l -m ctrl`

### Nested Hyprland

A second headless sway, kept off `$WAYLAND_DISPLAY` and `$SWAYSOCK`, hosts a persistent Hyprland: the host desktop's pinned version, restarted whenever it exits. It draws to its own 1280x800 output, `NESTED-1`, and the human can watch and drive it over a second VNC port. Use it to try Hyprland configs, plugins and Noctalia before they reach the host.

- Clients: set `WAYLAND_DISPLAY=hyprland-1`, e.g. `WAYLAND_DISPLAY=hyprland-1 foot &`
- Screenshot: `WAYLAND_DISPLAY=hyprland-1 grim -o NESTED-1 /tmp/hypr.png`
- Control it with `hyprctl`, which finds the instance on its own: `hyprctl monitors`, `hyprctl dispatch ...`, `hyprctl plugin load <path>`, `hyprctl reload`
- Its logs are `hyprland.log`, `nested-sway.log` and `wayvnc-hyprland.log` in `$XDG_RUNTIME_DIR/logs`. If it keeps crashing, `hyprland-restarts.log` there grows.

Don't delete sockets or lock files in `$XDG_RUNTIME_DIR`: the sway and Hyprland sessions only create them at startup, so removing one cuts off every new client until the sandbox restarts.

## Tools

Blender (Cycles with CUDA and OptiX) and a Python with torch (CUDA) and hy3dgen (Hunyuan3D) are installed; `~/projects/img2char3d` runs directly on them. Chromium is installed with its own sandbox off, since the container can't run it: open pages on the display with `swaymsg exec -- chromium <url>`, or render one without a window with `chromium --headless --screenshot=<file> --window-size=W,H <url>`. The Playwright MCP server drives its own Chromium, shown on the display, and the `playwright` CLI is installed. Nix talks to the host daemon. Get a missing tool with `nix shell nixpkgs#<package>` or `nix run nixpkgs#<package>`.

All sandboxes share a 20G memory limit; past it the kernel kills the largest process. Run one cargo build or test at a time, including across subagents and separate target dirs. Each one already uses every core, and several at once fill the limit with linkers.

## Disk

`~/projects` is on the host's disk, so anything you leave behind stays there.

- When a task finishes, delete the target dirs, worktrees, venvs, databases and other scratch you created for it. Leave only what the human needs to keep working.
- Before finishing, check what you added with `du -sh` and report anything over a few GB that you kept.

<!-- br (beads_rust, the issue tracker) was here; dropped in favor of native Claude tasks. `\`br\` (beads_rust, the issue tracker), ` used to prefix this line. -->
<!-- use \`br\` if native tasks not available -->

