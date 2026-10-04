# TODO

- [x] Investigate using the NVIDIA driver to limit FPS for unfocused games. No supported equivalent found on Linux 615.71.09; findings are in [the driver investigation](docs/nvidia-background-frame-limit.md).
- [x] Implement muting Steam games on workspace 5 when leaving that workspace and restoring their prior mute state when returning.
- [x] Activate and verify workspace 5 game audio muting on the desktop, including workspace changes, existing manual mutes and restarting a game while hidden.
- [ ] Compare Aion's XWayland and Wine Wayland paths for input latency, tearing, direct scanout and compatibility.
- [x] Activate and verify AION with the automatic standalone background limiter: 10 FPS unfocused, uncapped focused. Check real AION compatibility, focused overhead, tearing and direct scanout after restarting Steam and the game.
- [x] Configure and verify CPU placement: desktop on all cores, sandboxes on the second (non-V-Cache) CCD, and GameMode games on the first (V-Cache) CCD. Activated and verified on 2026-10-01, including topology, SMT siblings, all three running sandboxes, and AION's game threads.
- [x] Open web links in Firefox on the main monitor when it has a window, then switch to its workspace.
- [ ] Launch containerized Claude Code and Codex directly in Orca terminals without SSH, preserving Orca integrations. Forward pane/worktree identity, connect agent hooks and the Orca CLI to the desktop, and expose session files and managed Codex configuration as needed. Verify agent status, Orca commands/tools, session history and resume for both agents (`pkgs/agent-sandbox/`, `pkgs/orca-ade/`).

## Repository audit — 2026-10-02

- [x] **High:** Remove the local `j2bar` flake input while the bar is managed manually. Nix no longer fetches or installs it; desktop commands use the local development binary.
- [ ] **High:** Fix ARM package exports: `agent-sandbox` includes x86-only `hy3dgen`, and `game-background-limit` unconditionally pulls i686 packages. Restrict supported platforms or make dependencies conditional; verify `nix flake check --all-systems --no-build` (`pkgs/agent-sandbox/package.nix`, `pkgs/game-background-limit/package.nix`).
- [ ] **High:** Format `hosts/media/test-skin-trader-startup.py` with Ruff and verify the Nix treefmt check passes.
- [ ] **Medium:** Serialize task archive updates per task list and use unique temporary files. Concurrent completions currently leave stale blockers and can fail on shared `.tmp` files (`users/jesse/claude/archive-completed-task.sh`).
- [ ] **Medium:** Replace Codex configuration atomically during activation instead of deleting `config.toml` before writing its replacement; preserve saved settings on interruption or write failure (`users/jesse/codex.nix`).
- [ ] **Medium:** Prevent concurrent sandbox launches from selecting the same VNC ports. Lock allocation through container startup or let Docker allocate ports (`pkgs/agent-sandbox/agent-sandbox.sh`).
- [ ] **Medium:** Reject unterminated Mermaid blocks with a clear error instead of silently dropping the rest of the document and reporting successful PDF conversion (`pkgs/markdown-to-pdf/markdown-to-pdf.sh`).
- [ ] **Medium:** Add a Nix check that runs the media startup recovery tests in CI; building the host currently does not execute `hosts/media/test-skin-trader-startup.py` (`flake/checks.nix`).
- [ ] **Medium:** Fix fresh media bootstrap instructions to create `/secret` with restrictive permissions before writing `/secret/jesse.passwd` (`docs/bootstrap.md`).
- [ ] **Low:** Reconcile historical audit and agent documentation: mark resolved findings in `NIX_AUDIT.md` and update the Aion skill reference's limiter and CPU-placement status (`users/jesse/claude/skills/game-latency/references/aion-case.md`).
- [ ] **Policy review:** Review Pi's SSH and Samba access. Consider the shared SSH hardening module after provisioning a key; confirm whether unauthenticated LAN writes to `/media` are intentional (`hosts/pi/configuration.nix`, `hosts/pi/samba.nix`).

## Aesthetic refactoring — 2026-10-02

- [x] Refactor `pkgs/game-background-engine/engine.cpp`: expand compressed control flow and multi-statement lines, make function caching explicit instead of introducing caller variables through `REAL_CACHE`, and clearly group pacing, controller and graphics-hook code. Preserve initialization safety and the focused presentation path's performance constraints. Start here for the quickest readability improvement.
- [x] Refactor `pkgs/hyprsheet/main.cpp`: put sheet transitions and cleanup beside the state they govern, represent opening/open/closing explicitly, and make deferred callback lifetime handling consistent. Keep independent rendering flags separate. This is the largest ownership and lifecycle cleanup candidate.
- [x] Refactor `pkgs/agent-sandbox/agent-sandbox.sh`: consolidate repeated mount preparation, configuration seeding and credential copying into small operations such as `mount_readonly`, `seed_if_empty` and `copy_if_newer`. Make the main sequence clear: prepare directories, configure agents, assemble mounts, launch. Preserve each agent's existing mount and seeding behavior.
- [x] If the Noctalia network plugin is retained, refactor `users/jesse/hyprland-desktop/noctalia/plugins/network/network.luau`: organize discovery and sampling around a coherent network snapshot, keep menu interaction state separate, and make rendering consume those values rather than intertwining asynchronous callbacks and layout.
- [x] Refactor `pkgs/game-workspace-audio/game_workspace_audio.py`: introduce named stream/restoration records and separate mute-state decisions from journal persistence, stream identity validation and audio commands. Preserve journal-before-mutation ordering, manual mute restoration and recovery across stream/game restarts.

Verification: native and 32-bit engine builds/tests, hyprsheet and sandbox package builds, 17 audio tests, network plugin lint and mocked interactions, 32 sandbox launcher comparison scenarios, targeted formatting/lint, and flake evaluation passed. Live compositor visuals have not been tested.
