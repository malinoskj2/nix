---
name: sandbox-wayland-display
description: Bring up the agent sandbox's headless Wayland displays (sway with Xwayland and VNC, and optionally the nested Hyprland) on demand. Use inside the agent sandbox before anything that needs a display, such as screenshots with grim, swaymsg, opening windows or GUI apps, Chromium windows or the Playwright MCP's browser, Steam, Blender's UI, or trying Hyprland configs and plugins. Not for use outside the sandbox.
---

# Sandbox Wayland displays

Sandboxes start without displays unless launched with `--display`, which saves memory for agents that never draw anything. Start them when a task needs one.

```sh
sandbox-display up             # sway on $WAYLAND_DISPLAY, with Xwayland and VNC
sandbox-display up --hyprland  # also the nested Hyprland on hyprland-1
sandbox-display status
```

- `up` returns once the display accepts clients, then prints the status. It does nothing for a display that's already up, so run it whenever unsure.
- Start the nested Hyprland only when the task involves Hyprland, its plugins or Tohru; it costs about 100 MB more.
- Start the display before the first Playwright MCP browser call. A browser that already failed to open needs the MCP's `browser_close`, then a new navigation.
- The Unreal editor wrapper starts the sway display itself.
- The displays keep running after your command returns and stay up until the sandbox exits; there's no command to stop them.
- If `up` fails, tell the human straight away with the error and the relevant lines from `$XDG_RUNTIME_DIR/logs` (`sway-<renderer>.log`, `nested-sway.log`, `hyprland.log`). Mention it if the renderer is `pixman`, which means the GPU renderer failed and the display renders on the CPU.

Once it's up, use the display as the sandbox's CLAUDE.md describes: `swaymsg exec`, `grim`, `wtype` and the rest, and give the human `$AGENT_SANDBOX_VNC_URL` to watch.
