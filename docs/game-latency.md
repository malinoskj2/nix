# Game latency on the home desktop

The 30 September 2026 AION 2 investigation fixed first-frame tearing eligibility,
Steam/GameMode startup and runtime integration, cross-workspace fullscreen
placement and Wine pillarboxing. After the user activated the Nix configuration
and restarted the affected processes, AION showed active tearing and direct
GameMode registration, with the checked threads on the V-Cache CCD and at
best-effort I/O priority 0.

The remaining presentation limitation is the visible cursor: Hyprland forces
software cursors while tearing, which prevents direct scanout. The matching
Linux/NVIDIA/Aquamarine source explains why removing the checks alone would
leave invalid display updates. Composited fallback can still tear; its latency
overhead was not measured.

Upstream already tried separate hardware-cursor commits; cursor movement caused
frame throttling and stuttering, and the author removed the workaround. A proper
solution likely involves Linux DRM and GPU-driver support, followed by backend
and compositor changes. A kernel patch alone is not a demonstrated fix; see the
linked cursor investigation for the patch and discussion.

For the user's main concern, shooter gameplay with a hidden desktop cursor, the
existing stack can support tearing and direct scanout. A crosshair drawn inside
the game's frame does not require a separate cursor plane. CS2 is an expected
fit, not a locally verified result: confirm its game rules and actual gameplay
state before claiming success. Visible menu cursors can restore compositing.
Prioritise gameplay presentation and mouse delivery in the titles the user plays
over developing a visible-cursor workaround solely for shooter gameplay.

- [Session record, persistent fixes and validation limits](../users/jesse/claude/skills/game-latency/references/aion-case.md)
- [Cursor investigation, exact versions and upstream sources](../users/jesse/claude/skills/game-latency/references/cursor-tearing.md)
- [Reusable troubleshooting skill](../users/jesse/claude/skills/game-latency/SKILL.md)
- [Commands and interpretation](../users/jesse/claude/skills/game-latency/references/checks.md)

The skill directory is declared for both Claude and Codex in Home Manager.
Its source is shared; a Nix activation installs a new copy of changed skill
content. Building alone does not update the installed skills or restart any
running game, Steam, GameMode daemon or compositor.

## CPU placement

The `home` configuration leaves desktop applications and host services free to
use all 16 physical cores (logical CPUs `0-31`). The scheduler prefers the
V-Cache CCD but can use either CCD.

The topology was checked against sysfs L3 cache sizes and SMT siblings:

| Workload | Logical CPUs | Cache |
| --- | --- | --- |
| Desktop and host services | `0-31` | Both CCDs |
| Registered GameMode games | `0-7,16-23` | CCD0, 96 MiB L3 / V-Cache |
| Agent sandbox containers | `8-15,24-31` | CCD1, 32 MiB L3 |

`hosts/home/gaming.nix` sets GameMode's explicit `pin_cores` list and disables
core parking. This sets thread affinity for registered games, rather than a
cgroup boundary; games that do not register with GameMode are unaffected.
The desktop still shares each CCD with its restricted workload.

`hosts/home/configuration.nix` limits the entire `agent-sandbox.slice` with
`AllowedCPUs`, and `pkgs/agent-sandbox/agent-sandbox.sh` sets the matching Docker
cpuset. Nix builds requested from containers use the host Nix daemon, so they
retain access to all cores.

After activation, check the slice's `EffectiveCPUs` and each container's actual
`cpuset.cpus.effective`; existing containers can retain their old Docker cpuset
setting while inheriting the narrower slice limit. Recreating a sandbox picks
up the new launcher setting but stops its running agents. Check actual game
thread affinity with the diagnostic after GameMode reloads its configuration.
Building alone does not apply any of these limits.

After the user's switch on 1 October 2026, live checks confirmed all three running
sandboxes had Docker and effective cgroup CPU sets of `8-15,24-31`. The physical
desktop Hyprland and Firefox processes retained `0-31`. Every inspected thread
of all 19 registered GameMode clients used `0-7,16-23`, including all 198 threads
of AION's `GameThread` process. The host Nix daemon retained `0-31`.

## Running the diagnostic

`game-latency-check` is a Bash script with `jq` and standard Linux diagnostic
tools, installed on `home` by `hosts/home/gaming.nix` after Nix
activation. It discovers mapped `steam_app_<id>` windows on the physical Hyprland
session; it excludes nested/headless sessions and requires explicit selection
if more than one physical session exists. It reports all matching windows so a
launcher/helper is not silently treated as the game.

```sh
game-latency-check                         # discover running Steam game windows
game-latency-check 730 --delay 5            # CS2; return to gameplay before sampling
game-latency-check steam_app_3393110        # select AION by its Steam class
game-latency-check --pid 12345 --seconds 10 # native/custom-class game window PID
game-latency-check 730 --delay 5 --json      # structured findings and samples
nix run .#game-latency-check -- --help      # use the package before activation
```

The default presentation sample lasts about five seconds; `--seconds` accepts
1–60 and `--delay` accepts 0–60. Run it as the desktop user. Starting it from a
terminal can take focus from the game: use the delay and return to normal play.
It does not focus windows itself. Ctrl-C ends the check.

Checks cover window identity/backend/output, actual tearing/scanout and blockers,
global input/presentation options, layers, XWayland primary output where its
display can be identified, per-PID GameMode registration and mapped libraries,
Steam helper registration, daemon executable, per-thread scheduling/affinity/I/O
priority, L3 topology, CPU policy, swap/pressure, bounded recent errors, nominal
mouse USB intervals/power, DRM capabilities and an optional NVIDIA snapshot.

`OK`, `WARN`, `INFO` and `UNKNOWN` distinguish observed state from unavailable
evidence. A background or obscured game cannot receive a successful gameplay
presentation check; another window's scanout is not attributed to it. Warnings
need context and do not cause a nonzero exit status. Exit 2 means the diagnostic
could not select a session/game or encountered an operational error.

The script uses read-only queries and does not activate GameMode, change policy,
capture screens, read mouse events, or stop a game. It prints only selected
process environment keys and names/paths for ancestors, not full command lines
or environments. In-game VSync/Reflex/frame generation/caps, effective mouse
overrides, Wine child render geometry, raw-input delivery, exit-time restoration
and end-to-end latency still require separate verification.

The [TODO list](../todo.md) retains the XWayland/Wine Wayland comparison.
Final GameMode cleanup/restoration after game exit still needs runtime
verification. These checks did not establish zero added input latency.

## Workspace 5 game audio

`game-workspace-audio.service` mutes Steam game playback when workspace 5 is
hidden on the physical Hyprland desktop, then restores each stream's prior mute
state when returning or moving the game elsewhere. Workspace 5 remains audible
when it is visible and focus moves to the side monitor. Steam's UI, microphone
streams and unrelated applications are excluded. This works independently of
the background frame limiter and needs no Steam restart or launch options.

The helper reads PipeWire playback nodes and associates their process with
`SteamAppId`, including Wine audio subprocesses and native games with custom
window classes. If any window of the same app is outside workspace 5, its audio
stays audible. Games that hide their process environment cannot be identified
and remain untouched. Changes are checked every half second; audio can play for
that interval when a new stream appears or the workspace changes.

Normal stream mute and volume controls remain available. A stream muted before
leaving stays muted on return; automated muting remembers the original state.
While hidden, the helper enforces mute, so manual unmuting takes effect after
returning. It restores current streams when stopped or when compositor IPC is
unavailable. PipeWire's core cookie and object serial identify existing streams,
and the helper rechecks identity before addressing a recycled numeric node ID.

WirePlumber can save a mute when a game exits while hidden. A private restoration
journal at `$XDG_STATE_HOME/game-workspace-audio/mute.json` (normally
`~/.local/state/game-workspace-audio/mute.json`) retains the original state until
a verified Steam stream with the same app ID and WirePlumber restoration key
returns. That also recovers after a helper crash or stream recreation. Separate
launches of the same app share the workspace policy and restoration key; when a
replacement stream inherits the automated mute, it inherits the prior stream's
original state. For a newly created stream, a deliberate new user mute cannot
be distinguished from WirePlumber restoring the automated mute; the journal's
original state wins. Existing streams that were manually muted stay muted.
Stop the service while the game's playback streams still exist
before removing this feature; otherwise a saved mute can remain until the helper
runs again. A new stream may briefly inherit that mute before the next check.

## Background frame limit

After activation and restarting Steam, every newly launched Steam game inherits
`game-background-engine`: a standalone Vulkan layer and GLX/EGL preload that
limits presentation to 10 FPS while its launch's windows are unfocused. Focusing
any of those windows releases the limit. No per-game launch option, MangoHud
runtime, overlay, metrics sampler or Gamescope stage is required. Existing game
processes must be relaunched. Game settings, VSync and driver limits can still
cap focused gameplay.

Disable it for one game with this Steam launch option, then relaunch:

```sh
GAME_BACKGROUND_LIMIT=0 %command%
```

For a game outside Steam, use `game-background-limit GAME [ARGS...]`. The same
user controller must be running; without it the game remains uncapped. An old
`game-background-limit %command%` Steam launch option is harmless but redundant
and can be removed. Steam UI and known runtime helpers are excluded; automatic
registration requires a nonzero numeric `SteamAppId` or `SteamGameId`. Steam
shortcuts can use the automatic path when they retain those launch identifiers.

`game-background-limit.service` selects the physical Hyprland session and blocks
on its event socket. It reconciles windows on focus/open/close/workspace events;
while connected it does not poll focus or sample gameplay. Each launch creates a
random inherited token. Rendering processes register over a private same-user
Unix socket under `$XDG_CACHE_HOME/game-background-limit/control.sock` (normally
`~/.cache`), which stays visible inside pressure-vessel's shared home/cache.
The controller validates peer UID and native PID/start time. This directly
associates a native game even though constructor-set environment variables are
not visible in `/proc`; children are associated through the inherited token.
Two launches of the same game remain independent. Multiple windows from one
launch, including an inherited launcher, form a group: focusing any releases
that group's limit. A process that discards its token can register independently;
unreadable/unmatched window identity stays uncapped.

Startup without a window, closing the last window, unavailable focus data or a
compositor disconnect releases the limit. Socket EOF, including controller
`SIGKILL`, clears the game's atomic cap flag and wakes an in-progress background
sleep immediately. The receiver reconnects while disconnected. The service
restarts after failure and removes a stale socket before binding; no per-launch
config files or stale caps remain. A fork followed by exec initializes normally.
A child continuing graphics without exec has no receiver thread and deliberately
stays uncapped; driver support for graphics after fork is outside this limiter's
scope.

The complete focused pacing check is one atomic flag load and return. GL calls
also load their cached downstream pointer; Vulkan calls look up their queue's
device dispatch before forwarding. The engine performs no focused timing clock,
config read, pacing lock or sleep. A separate blocking receiver updates the flag.
Background pacing compensates frame work and uses monotonic, interruptible
condition waits. Focus transitions still include compositor event delivery,
bounded `hyprctl` queries and thread scheduling; the focused fast path does not
establish zero total hooking overhead or zero added input latency.

Steam's FHS profile preserves GameMode and preloads an explicit store path with
`${PLATFORM}`, selecting the 64- or 32-bit engine after pressure-vessel replaces
`LD_LIBRARY_PATH`. Both Vulkan manifests are supplied through `XDG_DATA_DIRS`
and imported by pressure-vessel. The engine has no dependency on MangoHud or
libstdc++. It hooks Vulkan instance/device loader chains and queue presentation,
GLX swap/proc-address entrypoints, and EGL swap/proc-address entrypoints including
KHR/EXT damage swaps. It is not a guarantee for games using custom loader paths,
other presentation APIs or anti-cheat restrictions.

Validation on 1 October 2026:

- Package checks cover early graphics initialization before the preload
  constructor, automatic game/helper/opt-out guards, two-device dispatch,
  instance/device-GPA destruction and recreation, supported/null GL proc-address
  routes, focused no-clock/no-lock behavior, work-time compensation, cap release
  during sleep and fork fail-open behavior, for both pointer widths.
- Controller checks cover direct native identity, inherited tokens, independent
  launch groups, focus loss/regain, last-window close, compositor disconnect and
  an actual controller process killed while its client stays alive.
- Independent isolated Xvfb/lavapipe Vulkan rendering, 64- and 32-bit, completed
  30 frames at 10 FPS in 3.09/3.20 seconds. Releasing the cap after one second
  completed a 2,000-frame run in 1.40/1.41 seconds; controller EOF gave
  1.44/1.42 seconds. GLX `glxgears` reported 10.076 FPS.
- The final automatic Steam profile and installed sniper pressure-vessel runtime
  also rendered both architectures without a per-game wrapper or manually
  supplied preload/enable flags: 30 capped frames took 3.73/3.73 seconds including
  runtime startup, and the one-second cap-release runs took 2.06/1.69 seconds.
  The profile selected the correct preload architecture throughout the runtime.
- The isolated EGL demos crashed before registration even without the limiter.
  EGL hook/proc-address checks pass, but actual EGL presentation remains to be
  verified in a working renderer.

The package and software-renderer checks above did not activate configuration,
restart Steam, or change live game caps/focus. A subsequent AION session on
1 October confirmed the game launches with both GameMode and the limiter loaded.
Read-only XPresent completion events on its rendering child measured 72–112 FPS
while focused and approximately 10 FPS after the user switched workspaces. A
separate five-second background sample counted exactly 50 frames. These samples
verify the background cap, not focused overhead, frame times, tearing or direct
scanout. The return-to-focus transition was outside the recorded sample. See the
[engine's source and license notes](../pkgs/game-background-engine/SOURCES.md)
for the narrow MangoHud code adaptations and loader references.

### Steam launched from a development shell

A development build of the bar inherited large Nix compiler flags and passed them
to Steam. Wine's preloader crashed in the dynamic loader before creating a game
window with an approximately 50 KiB environment. Restarting Steam with a clean
desktop environment restored AION startup without disabling either preload.

The Steam profile in `hosts/home/gaming.nix` now removes `BINDGEN_EXTRA_CLANG_ARGS`,
`NIX_CFLAGS_COMPILE`, `NIX_CFLAGS_LINK` and `NIX_LDFLAGS` automatically. Testing the
built Steam runtime with the running bar's environment removed 17,551 bytes of
compiler flags while retaining the display, GameMode and limiter configuration.
The home host build passed; activation and a subsequent Steam restart are needed
to use this profile for future launches.
