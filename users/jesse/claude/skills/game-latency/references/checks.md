# Checks and interpretation

Use commands selectively. They are examples for Hyprland/Linux, not a script to
run blindly. Missing permissions or tools are gaps in evidence, not proof of a
broken setup. Discover current package/source paths instead of storing Nix store
hashes. Check version-specific syntax before any mutation.

## Packaged diagnostic

In this repository, `game-latency-check [Steam-app-ID|steam_app_ID]` covers the
read-only checks that can be automated. With no ID it discovers mapped Steam
game windows; `--pid PID` selects a native/custom-class window. Use `--delay 5`
to let the user return to gameplay, `--seconds 10` for a bounded sample and
`--json` for structured output. `--instance` accepts an exact physical session
signature. Before activation, run `nix run .#game-latency-check -- <arguments>`.

Use the report to select follow-up checks, not to claim zero latency or silently
fix warnings. UNKNOWN is missing evidence; a background game's presentation is
not a gameplay pass. The report lists the game settings, mouse delivery and
lifecycle checks it cannot establish. Do not start it after a stop-monitoring
request solely because documentation/config work continued. Avoid a Nix build
during a gameplay measurement; build first, then run the already-built binary.

## Find the physical session and game

`hyprctl instances` and `hyprctl version` identify compositor instances/builds.
When several instances exist, select the physical desktop with `hyprctl -i
<instance> ...`; use that selection consistently for all later commands. A
`NESTED-*` output is not the desktop's DRM output. Do not infer session identity
from the agent terminal's inherited environment alone.

```sh
hyprctl -j clients | jq '.[] | {
  address, class, initialClass, pid, workspace, monitor,
  fullscreen, xwayland, contentType, tearingHint
}'
hyprctl -j monitors | jq '.[] | {
  id, name, width, height, refreshRate, scale, transform, activeWorkspace,
  solitary, solitaryBlockedBy, activelyTearing, tearingBlockedBy,
  directScanoutTo, directScanoutBlockedBy, hardwareCursorsInUse
}'
hyprctl -j layers
hyprctl -j devices
```

Select the actual game window, not a launcher, crash dialog or settings helper.
Use its monitor ID to identify the physical output. Workspace 5, 1080p/360 Hz and
`steam_app_3393110` belonged to the original game; do not assume them for another.
Inspect only the selected PID's command line and relevant environment variables
if a wrapper/runtime question remains. Avoid dumping full environments, which
may contain unrelated secrets. Inspect Steam launch options without changing
them or rewriting Steam's local config while it is running.

A Windows game can use Wine's X11 or Wayland backend; native Wayland does not
require the game itself to have a Linux port. XWayland acts as a Wayland client
and does not inherently insert another compositor like nested Gamescope.
An XWayland game can qualify for direct scanout and tearing. GE-Proton documents
an opt-in Wayland driver, but supported options differ between Proton builds.
Verify the exact build before suggesting an option. Do not force a global
backend switch as an assumed latency fix; compare presentation, relative mouse
input, focus, launcher compatibility and required Steam features for that game.
See [XWayland architecture](https://wayland.freedesktop.org/docs/book/Xwayland.html)
and [GE-Proton options](https://github.com/GloriousEggroll/proton-ge-custom#options).

## Presentation

For wrong-monitor or pillarboxing symptoms, compare the Hyprland window geometry
with `DISPLAY=<physical-X-display> xwininfo -id <X-window-id> -tree`. A fullscreen
outer window can contain a smaller Wine rendering child. Use `xrandr --listmonitors`
to check the XWayland primary output as well as the physical monitor layout.
With no primary selection, Wine may choose the portrait display at (0, 0).
An authorised `xrandr --output <main-output> --primary` experiment changes the
primary designation without moving outputs; a game restart may be needed to
discard cached display selection. Do not infer a fix just from the command
succeeding, or substitute an XWayland display inherited from a nested session.

```sh
hyprctl getoption general:allow_tearing
hyprctl getoption render:direct_scanout
hyprctl getoption cursor:no_hardware_cursors
```

On this repository's Hyprland 0.56.2, `direct_scanout = 2` restricts scanout to
game content; `1` allows eligible fullscreen surfaces more broadly. Confirm
semantics in the running version. Lua mutations use `hl.config`/`hl.window_rule`
through `hyprctl eval`; legacy `keyword`/`windowrulev2` examples are not portable
to this configuration. Reading options with `getoption` is still supported.

For a short gameplay sample, select the already identified output by name and
collect only its state. For example, with `game_output` set to that output and
the correct instance selected:

```sh
for sample in $(seq 1 30); do
  hyprctl -j monitors | jq -c --arg output "$game_output" '
    .[] | select(.name == $output) | {
      observedAt: now, name, activeWorkspace, solitary, solitaryBlockedBy,
      activelyTearing, tearingBlockedBy, directScanoutTo, directScanoutBlockedBy,
      hardwareCursorsInUse
    }'
  sleep 1
done
```

Do not leave a polling loop running after the requested observation ends.
Compare the sampled active workspace and window identity to the game, rather
than interpreting samples taken after focus changed as gameplay failures.

Interpret the monitor fields separately:

- `solitary` identifies a candidate surface; use `solitaryBlockedBy` to explain
  why there is no candidate. Fullscreen alone does not establish eligibility.
- `directScanoutTo` identifies the scanout surface. Correlate it with the game's
  address (hex formatting may differ), blocker fields and repeated samples.
  Merely enabling scanout or observing a nonzero pointer once is insufficient.
- `activelyTearing` is evidence of actual asynchronous presentation.
  `allow_tearing`, an immediate rule and VSync OFF establish intent/eligibility,
  not successful torn frames. Scanout can be active while tearing is false.
- `CONTENT` points toward content classification. `WINDOW` points toward the
  window's tearing policy/hint. `HW_CURSOR` is relevant to cursor presentation;
  inspect its conditions before changing cursor policy globally. Other blockers
  must be interpreted using the running source, not guessed away.
- `SW` means software renders/cursors; it does not establish CPU software
  rendering. Inspect the actual scanout check and pointer manager. A GPU-drawn
  software cursor can block scanout while asynchronous compositing stays active.
- `NOT_TORN` can be normal between asynchronous frames. Persistent false tearing
  with only `NOT_TORN`, during active gameplay and after checking eligibility,
  justified source inspection in the original case. It is not sufficient by
  itself to diagnose that bug in a different build.

Overlays, notifications, recording, visible cursor state, scaling/transforms,
buffer formats, colour processing and plugins can affect eligibility. Inspect
what is actually active. Do not indiscriminately disable the desktop's effects.
Check VRR separately from VSync and tearing; it is not synonymous with either.
An FPS counter above display refresh is not proof that VSync or compositor
scheduling is absent.

If support is in doubt, use read-only DRM capability queries (e.g. libdrm
`drmGetCap` for `DRM_CAP_ASYNC_PAGE_FLIP` and `DRM_CAP_ATOMIC_ASYNC_PAGE_FLIP`) on
the physical GPU. Do not set DRM master, modes or properties as a diagnostic.
Driver capability support still does not prove that this frame used that path.
It also does not establish that cursor position/image changes are allowed in an
asynchronous commit. For that distinction and the September 2026 NVIDIA findings,
read [cursor-tearing.md](cursor-tearing.md). A source comment naming the kernel
is a lead; inspect the actual kernel, driver and backend before declaring it
obsolete or saying the hardware fundamentally cannot display both.

Direct scanout avoids compositor rendering. Its fallback adds work and may add
latency, but is not automatically a full refresh wait. Check whether the fallback
commits with immediate or synchronised presentation in the running renderer.
Cursor appearance and game camera/input response are separate observations;
neither compositor state nor USB polling specifications measure their latency.

## Mouse and system

Inspect `input:accel_profile`, `input:sensitivity`, `input:follow_mouse`, per-device
overrides and game raw/relative input settings where available. Pointer scaling
or acceleration changes motion behaviour; they are not automatically latency
defects. Verify the device matched by an override. Test a suspected cursor
blocker only within the requested fix scope, save its original value and restore
it when the experiment ends.

Locate the mouse's event node with the device list and `/proc/bus/input/devices`;
`udevadm info --query=path --name=/dev/input/eventN` identifies its sysfs path.
Read that device's USB speed, interface/endpoint interval and
`power/control`/`power/runtime_status`. `lsusb -t` and targeted `lsusb -v -s
<bus:device>` can help. Full-speed `bInterval=1` is nominally 1 ms; high-speed
interrupt endpoints encode intervals differently. Neither measures delivered
event rate. Avoid globally disabling USB autosuspend or changing polling rates
without a demonstrated problem.

With `game_pid` set to the selected, still-running game process:

```sh
ps -p "$game_pid" -o pid,comm,ni,cls,psr
taskset -pc "$game_pid"
rg 'Cpus_allowed_list|Threads' "/proc/$game_pid/status"
gamemodelist
id -nG
getent group gamemode
journalctl --user -u gamemoded -b --since '10 minutes ago' --no-pager
systemctl status scx --no-pager
cat /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
cat /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference
vmstat 1 5
journalctl -k -b -n 100 --no-pager
```

Adapt service names and sysfs paths to the host. Check active swap-in/out and
memory pressure, not just allocated swap. A `powersave` governor under active
AMD P-state can still boost; inspect EPP, observed clocks and helper failures
before declaring a CPU bottleneck. Respect hardware-specific affinity and
V-Cache scheduling: copy neither a PID nor a CPU set from an earlier game.

GameMode registration is distinct from successful privileged optimisations.
Compare effective login groups with configured membership and check journal
denials. `gamemoded -t` exercises optimisations; it is not a passive query. Manual
registration or `gamemoderun` is an experiment/launch change, not persistence.
For automatic Steam preload, check both library architectures and propagation
through the actual runtime, plus that UI/helper processes do not keep GameMode
active after games exit. Do not blindly preload GameMode into the whole desktop.

### Steam and GameMode failures

Check the actual game PID, rather than treating a registered launcher as proof:

```sh
rg 'libgamemode(auto)?\.so' "/proc/$game_pid/maps"
busctl --user call com.feralinteractive.GameMode /com/feralinteractive/GameMode \
  com.feralinteractive.GameMode QueryStatus i "$game_pid"
busctl --user status com.feralinteractive.GameMode
ionice -p "$game_pid"
```

With GameMode 1.8.2, `QueryStatus` returning `i 2` identifies a directly
registered PID. Require the companion `libgamemode.so` as well as the automatic
loader to be mapped, and inspect logs for registration errors. Check effective
affinity and I/O priority across the game's threads when verifying those effects;
the process leader's values alone are insufficient. Account for inherited
optimisations in child processes and helpers scoped to a running game prefix.

Pressure-vessel can rewrite a soname preload to `/run/host/lib`, whose absolute
`/usr` symlink resolves inside the container. An immutable store-path preload
avoids that failure. This repository selects 32/64-bit entries with the loader's
literal `${PLATFORM}` token. Steam can also replace `LD_LIBRARY_PATH`, so inspect
the automatic loader's RUNPATH and its ability to dlopen the companion library.
Verify registration inside the actual installed Steam runtime for both
architectures; a host-only library-load test missed this failure in the AION case.

If Steam reports an unexpected startup error after preload changes, inspect
client/helper stderr and D-Bus errors before changing the bar launcher. The local
Steam-specific client gates registration on a nonzero numeric Steam game ID,
guards forked-child unregister calls and handles a null D-Bus pending call.
Those are client startup fixes, separate from the daemon's priority handling.

For `Skipping ioprio ... was (0) ... expected (4)`, read the scheduling class as
well as priority data. Unset `NONE/0` derives effective priority from CPU niceness;
explicit `BE/0` is already the requested boost. The local patch distinguishes
them. Warnings for children inheriting explicit `BE/0` do not mean optimisation
failed; verify actual thread priorities before changing the guard.

After activation, compare the running daemon binary with the deployed package.
This unit's security-wrapper `ExecStart` path stays constant across builds, so a
new system generation alone did not replace the old process. Its package restart
trigger now records that dependency; verify the actual process after deployment.
Also check GameMode releases clients and restores policy after the last game
exits, when that lifecycle test is authorised; do not close a game just to test it.

On NVIDIA, short `nvidia-smi` queries can check driver, utilisation, clocks, power
and processes. Use equivalent read-only tools on other GPUs. Correlate samples
with gameplay; sustained GPU load can explain low FPS without proving an extra
compositor queue. Inspect launch wrappers and existing limiter/presentation
overrides in the relevant Steam/Proton environment. Do not force mailbox/FIFO,
disable synchronisation mechanisms or install an overlay without evidence.

For current explanations, verify with the running source and primary docs:
[Hyprland source](https://github.com/hyprwm/Hyprland),
[GameMode](https://github.com/FeralInteractive/gamemode),
[Gamescope](https://github.com/ValveSoftware/gamescope),
[Proton](https://github.com/ValveSoftware/Proton),
[DXVK](https://github.com/doitsujin/dxvk) and
[vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton).
