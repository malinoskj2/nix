# TODO

- [x] Investigate using the NVIDIA driver to limit FPS for unfocused games. No supported equivalent found on Linux 615.71.09; findings are committed on `task/nvidia-driver-limiter`.
- [x] Implement muting Steam games on workspace 5 when leaving that workspace and restoring their prior mute state when returning.
- [ ] Activate and verify workspace 5 game audio muting on the desktop, including workspace changes, existing manual mutes and restarting a game while hidden.
- [ ] Compare Aion's XWayland and Wine Wayland paths for input latency, tearing, direct scanout and compatibility.
- [ ] Activate and verify AION with the automatic standalone background limiter: 10 FPS unfocused, uncapped focused. Check real AION compatibility, focused overhead, tearing and direct scanout after restarting Steam and the game.
- [x] Configure and verify CPU placement: desktop on all cores, sandboxes on the second (non-V-Cache) CCD, and GameMode games on the first (V-Cache) CCD. Activated and verified on 2026-10-01, including topology, SMT siblings, all three running sandboxes, and AION's game threads.
- [x] Open web links in Firefox on the main monitor when it has a window, then switch to its workspace.
