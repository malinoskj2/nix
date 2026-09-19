# Sandbox

You are running inside a Docker sandbox. You may read anything you can find in the container, including the directories mapped from the host:

- `~/projects` and `~/nix`, read-write, at the same paths as on the host
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

## Tools

`br` (beads_rust, the issue tracker) is installed. Nix talks to the host daemon. Get a missing tool with `nix shell nixpkgs#<package>` or `nix run nixpkgs#<package>`.
