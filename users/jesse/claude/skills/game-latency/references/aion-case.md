# AION 2 investigation

Historical record from 30 September 2026. Re-check the deployed generation,
running binaries and current game before applying these findings elsewhere.
The final runtime checks supersede earlier build-only and activation-pending
states in this session. No end-to-end input latency was measured.

## Final observed state

- AION 2 used XWayland, class `steam_app_3393110`, fullscreen on workspace 5,
  DP-2 at 1920×1080/360 Hz. The portrait DP-1 was left of the main display.
- Supplied settings showed VSync OFF, frame generation OFF and Reflex BOOST.
  Very High graphics were the user's preference; graphics tuning was outside
  the compositor/input investigation. Menu FPS was not a gameplay benchmark.
- After the user activated Nix changes and restarted Hyprland/Steam/game,
  focused samples showed tearing active. A final 12-second sample showed
  tearing in all samples and scanout blocked by `SW` while the cursor was
  visible. Earlier gameplay checks observed direct scanout with a hidden cursor.
  The visible-cursor fallback remained unresolved; see
  [cursor-tearing.md](cursor-tearing.md) for the kernel/driver/backend evidence.
- The actual game mapped both `libgamemodeauto.so` and `libgamemode.so`;
  GameMode's D-Bus `QueryStatus` returned `i 2` for the game PID.
  The running daemon was the patched 1.8.2 build, rather than the old process
  left behind by an earlier activation.
- All 193 game threads checked had affinity `0-7,16-23`, the first V-Cache CCD
  including its SMT siblings, and best-effort I/O priority 0. CPU policies
  reported performance governor/EPP; scx_lavd and its V-Cache preference were
  active. These observations did not implement the separate sandbox CCD TODO.
- Mouse checks found flat acceleration, sensitivity 0, no follow-mouse focus
  switching, nominal 1 ms full-speed USB interval and active USB power state.
  They did not measure event delivery, game raw input or click-to-photon delay.

## Tearing and scanout

The game initially supplied neither a useful tearing hint nor game content
classification. Game-only scanout was blocked by `CONTENT`. A live immediate
rule and temporary `render.direct_scanout = 1` allowed scanout, but repeated
cursor-hidden samples still showed tearing false with `NOT_TORN`.

Source inspection found `CWindow::commitWindow` checking `!isTearingBlocked()`
before setting the next-render torn request. Including `TC_NOT_TORN` made that
first-frame eligibility circular. An
[upstream report/comment](https://github.com/hyprwm/Hyprland/issues/16035#issuecomment-5462958183)
described matching control flow. Check its current status when reviewing a new
version; an old report is not proof that the defect still exists.

The persistent implementation is:

- `hyprland.lua`: immediate presentation and game content for
  `^(steam_app_[0-9]+|gamescope)$`, plus immediate presentation for native game
  content. This covers those identifiers, not every Steam executable/class.
- `look.lua`: `allow_tearing = true`, `direct_scanout = 2`. The temporary broader
  scanout setting was restored. Content tagging may require a recreated window.
- `hosts/home/tearing-first-frame.patch`: ignore only `TC_NOT_TORN` for the
  initial eligibility check; retain real blockers, including the hardware
  cursor check. `gaming.nix` applies it only to the physical desktop's Hyprland
  0.56.2 package with a version assertion.

The build passed and subsequent user restarts produced live tearing. Briefly
forcing software cursors during the original false-tearing investigation did
not fix it; that experiment was restored. The later software-cursor fallback
comes from upstream Hyprland's active-tearing policy, not a global cursor
override introduced here.

## Steam startup and automatic GameMode

There were several independent failures; avoid treating any one success as proof
of the whole launch path:

1. Privileged GameMode CPU helpers failed because the effective login session
   lacked the `gamemode` group. Nix now declares the user's group membership.
2. Steam launched from the bar reported an unexpected error. An automatic client
   preloaded into Steam/startup helpers could abort on a disconnected D-Bus
   pending call. The Steam-specific patch gates registration on a nonzero
   numeric `SteamAppId` or `SteamGameId`, guards forked children from unregistering
   their parent, and handles failed/null D-Bus replies. It covers non-Steam
   shortcuts with a valid game ID too; game-prefix helpers can still register.
3. Pressure-vessel rewrote the soname preload to a missing `/run/host/lib` path.
   Its absolute symlink resolved into the inner runtime. The preload now uses
   immutable store paths with `x86_64`/`i686` entries selected by `${PLATFORM}`.
4. Seeing `libgamemodeauto` mapped still missed a failure: Steam replaced the
   library search path, and the loader could not dlopen `libgamemode.so`.
   Adding its own library directory to RUNPATH fixed actual registration.
5. The daemon discarded I/O scheduling class bits and mistook Linux's unset
   `NONE/0` for explicit best-effort priority 0, skipping the default-priority
   boost. `gamemode-ioprio.patch` derives unset priority from CPU niceness,
   preserves explicit realtime/idle classes and leaves the error sentinel intact.
6. Nix activation left the old daemon running because its security-wrapper
   `ExecStart` path did not change. The unit now has a package restart trigger.
   The user restarted the daemon, and its new executable was checked.

`hosts/home/gaming.nix` wires the Steam-specific library for both architectures,
daemon patch, group membership, restart trigger and filters for persistent Steam
UI/runtime services. The Steam UI should not keep GameMode active after games
exit. Game-prefix helpers inheriting the game ID are distinct from that UI.

Validation included automatic registration with both libraries mapped for
32-bit and 64-bit processes through the installed Steam Linux Runtime 4;
game-ID/fork/null-D-Bus tests; and I/O boost/restore across threads, including
custom priorities, idle class, errors and niceness-derived unset priority.
The Nix desktop build passed. A subsequent AION launch confirmed the actual
game's registration, mapped libraries, thread affinity and I/O priorities.

Some helper warnings still said priority was 0 instead of expected 4: their
explicit `BE/0` had already been inherited. All game threads checked were at
the requested boost. Cleanup/restoration after the last game exits was not
verified for the final rollout; record it as an outstanding lifecycle check.

## Workspace and fullscreen geometry

A floating X11 position request put AION on the always-visible `side` workspace
while its monitor/rendered position remained DP-2. It then covered the main
display across workspace switches. Moving it to workspace 5 restored agreement
and scanout. The Steam-wide `steam-games-placement` rule now assigns
`^steam_app_[0-9]+$` to the main monitor/workspace 5 and suppresses
`x11configurerequest`. Discover the class for games outside that pattern.

Pillarboxing was separate: the fullscreen outer window was 1920×1080, while
Wine's rendering child was 1350×1080 at x=285. XRandR had no primary output and
Wine enumerated the portrait display at (0, 0) first. Setting DP-2 primary and
restarting AION restored a 1920×1080 child at x=0; the user confirmed the bars
were gone. The config repeats primary selection at Hyprland startup, config
reload and monitor layout changes, using the declared `xrandr` executable.
It does not change the output layout or game's resolution setting.

For explicit session exit requests, `pkgs/hyprland-quit/package.nix` wraps
`hyprctl eval 'hl.dispatch(hl.dsp.exit())'` and requires the current session's
instance signature. The old `hyprctl dispatch exit` syntax failed on this Lua
build. Exiting/restarting a session is not part of a read-only latency check.

## Remaining work and limits

- Visible software cursors block scanout during tearing on this stack. A
  separate-cursor-commit workaround was already tried upstream and removed after
  stuttering/frame-throttling reports. A supported backend/kernel/driver path
  would need development and runtime testing; deleting the guards is not a fix.
  See [cursor-tearing.md](cursor-tearing.md) for upstream evidence and the lesser
  relevance to shooter gameplay with hidden cursors. CS2 was not tested locally.
- No Gamescope wrapper or 10 FPS unfocused limiter was installed. Gamescope's
  unfocused cap still leaves its compositor in the focused presentation path.
  The MangoHud/focus-listener alternative remains a TODO, with overhead and
  compatibility unverified.
- Comparing XWayland with Wine's Wayland backend remains a TODO. XWayland did
  qualify for tearing and direct scanout here; native Wayland is not an
  established latency improvement for this game.
- Sandbox placement on the second CCD remains a TODO. Verified game affinity
  does not mean the host and every sandbox were separated across CCDs.
- No claim of zero added latency follows from these checks. Tearing state,
  scanout eligibility and effective optimisations are pipeline observations,
  not end-to-end measurements.

Reproducing this workflow means checking the new game's evidence and persisting
appropriate fixes. Distinguish configured, built, activated, restarted and
observed states; do not reuse historical PIDs, instance signatures or store paths.
