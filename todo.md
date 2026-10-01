# TODO

- [ ] Wire zcode into Orca's left-pane activity indicator
  - Orca's pane status is fed only by agent-status hooks POSTing to its local
    endpoint; zcode isn't in Orca's supported agent list, so no hooks get
    installed and zcode panes never show "working" in the left pane.
  - Plan: add an Orca-shaped hooks block to `~/.zcode/settings.json` (zcode is
    Claude-Code-compatible: it supports `--settings` and Claude-style hooks)
    pointing at `~/.orca/agent-hooks/claude-hook.sh`, so zcode posts to the
    same endpoint Orca's claude/codex integrations use. Depends on Orca
    injecting `ORCA_AGENT_HOOK_PORT`/`ORCA_AGENT_HOOK_TOKEN`/`ORCA_PANE_KEY`
    into the pane env.
  - Reference: `~/.orca/agent-hooks/claude-settings.json` (hook shape),
    `~/.config/orca/agent-hooks/endpoint.env` (endpoint), and
    `~/.config/orca/agent-hooks/last-status.json` (verify events arrive).
  - Alternative: ask upstream (stablyai/orca) to add zcode as a supported
    agent.

- [ ] Compare Aion's XWayland and Wine Wayland paths for input latency, tearing, direct scanout and compatibility.
- [ ] Investigate MangoHud with a Hyprland focus listener for a 10 FPS unfocused game limit and uncapped focused gameplay, with the overlay hidden; verify overhead and Aion compatibility without Gamescope.
- [ ] Configure CPU placement so sandboxes run on the second CCD and the host plus games run on the first (V-Cache) CCD; verify CPU topology and include the corresponding SMT threads.
- [ ] Investigate making links always open in Firefox on the main desktop and switching focus to that Firefox window and its workspace when a link opens.
