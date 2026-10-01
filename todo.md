# TODO

- [ ] Compare Aion's XWayland and Wine Wayland paths for input latency, tearing, direct scanout and compatibility.
- [ ] Activate and verify AION with `game-background-limit %command%`: hidden MangoHud, 10 FPS unfocused, uncapped focused. Implementation, listener tests, isolated rendering/runtime checks and host build passed; real AION compatibility, focused overhead, tearing and scanout remain to be checked after relaunch.
- [x] Configure and verify CPU placement: desktop on all cores, sandboxes on the second (non-V-Cache) CCD, and GameMode games on the first (V-Cache) CCD. Activated and verified on 2026-10-01, including topology, SMT siblings, all three running sandboxes, and AION's game threads.
- [ ] Investigate making links always open in Firefox on the main desktop and switching focus to that Firefox window and its workspace when a link opens.
