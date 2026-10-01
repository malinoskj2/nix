# TODO

- [ ] Compare Aion's XWayland and Wine Wayland paths for input latency, tearing, direct scanout and compatibility.
- [ ] Activate and verify AION with the automatic standalone background limiter: 10 FPS unfocused, uncapped focused. Check real AION compatibility, focused overhead, tearing and direct scanout after restarting Steam and the game.
- [x] Configure and verify CPU placement: desktop on all cores, sandboxes on the second (non-V-Cache) CCD, and GameMode games on the first (V-Cache) CCD. Activated and verified on 2026-10-01, including topology, SMT siblings, all three running sandboxes, and AION's game threads.
- [x] Open web links in Firefox on the main monitor when it has a window, then switch to its workspace.
