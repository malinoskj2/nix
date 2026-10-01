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

## Background frame limit

`game-background-limit` launches a game through MangoHud with the overlay hidden,
a 10 FPS limit while its windows are unfocused, and no MangoHud frame limit while
one of its windows is focused. After activating the configuration and restarting
Steam, set the game's Steam launch options to:

```sh
game-background-limit %command%
```

For a game outside Steam, use `game-background-limit GAME [ARGS...]`. Remove the
wrapper and relaunch to disable it. Existing game processes are unaffected by
building or activating this configuration; the wrapper must start the game.
The wrapper replaces `MANGOHUD_CONFIG` and `MANGOHUD_CONFIGFILE` for that launch,
so an existing MangoHud configuration cannot supply a competing cap or overlay.
Game settings, VSync and driver limits can still cap focused gameplay.

Every launch has a separate private file under
`$XDG_CACHE_HOME/game-background-limit/launch-*/MangoHud.conf` (the cache home
defaults to `~/.cache`). The directory is private to the user. Home/cache stays
shared inside pressure-vessel, which replaces `/run/user` with a private mount
and would hide a runtime-directory config from the game. The wrapper watches the
physical Hyprland session's event socket and writes that file only when the
desired cap changes. It identifies the launch's windows by the exact inherited
`MANGOHUD_CONFIGFILE` value in each window PID's environment, rather than a Steam
app ID or window class. Two launches of the same game therefore have independent
limits. Multiple windows from one launch, including a launcher that retains the
same environment, form one group: focusing any of them uncaps that launch.
Processes that discard the marker or have unreadable environments cannot be
identified; an unidentified launch remains uncapped.

No game window at startup, a closed last window, unavailable focus data, or a
disconnected compositor releases the cap. The listener retries a disconnected
session and reconciles on reconnection. While connected it blocks on events and
game exit; it does not periodically query focus or sample gameplay. A separate
watchdog blocks on a pipe and restores the uncapped file if the listener dies,
including `SIGKILL`. Normal exit removes the directory. A killed listener can
leave its small, uncapped cache file; it has no effect on a new launch's unique
file and can be removed after that game exits. The launched command must remain alive until its game
exits, as Steam's Proton supervisor normally does.

This uses MangoHud's supported file watcher, not synthesized keypresses or a
MangoHud source patch. MangoHud 0.8.3's control socket supports HUD, logging and
FCAT toggles, but does not set the frame limit. Its file watcher polls every
100 ms and waits another 100 ms before reloading, so cap transitions usually
take roughly 100–200 ms after a focus event, plus scheduling/query time. A frame
already sleeping at the background limit can also finish its sleep. A focused
limit of zero takes MangoHud's limiter's no-sleep path. The hidden HUD skips its
overlay drawing and frame-statistics update; CPU/GPU display statistics,
logging and overlay/limit hotkeys are disabled explicitly. MangoHud still loads
its layer, checks keybindings and watches its config; its NVIDIA GPU sampler can
still run. This is not a claim of zero focused overhead.

Steam's FHS environment includes the wrapper and both architectures' MangoHud
libraries/manifests. Nix's MangoHud launcher adds store paths to
`LD_LIBRARY_PATH` and `XDG_DATA_DIRS`, enables the Vulkan layer with `MANGOHUD=1`,
and loads its OpenGL shim where supported. The wrapper uses a copied launcher
whose shim preload is an explicit store path with a `${PLATFORM}` token,
selecting the appropriate architecture even after pressure-vessel replaces
`LD_LIBRARY_PATH`. It preserves the existing GameMode preload. The upstream Nix package supplies the
32-bit shim/library and Vulkan manifest alongside the 64-bit versions. The
pressure-vessel runtime imports the Vulkan manifests into its own overrides
directory. Isolated shell checks confirmed the shared config, both library
architectures and imported manifests there without missing-shim preload errors.
Actual AION startup still needs verification after relaunch.

Validation on 1 October 2026:

- Listener tests cover startup, independent launch markers, focus loss/regain,
  multiple windows, last-window close/reopen, disconnect/reconnect, malformed
  events/JSON, and the actual listener being killed while the game stays alive.
- Package and full `home` host builds passed; no configuration was activated.
- A separate Xvfb display with software Vulkan (`lavapipe`), immediate present,
  and a 64×64 `vkcube` confirmed the real MangoHud reload: 30 frames at 10 FPS
  completed in 3.24 seconds including startup/exit. Releasing a 10 FPS cap after
  one second let a 2,000-frame run finish in 1.64 seconds.
- The same rendering test through Steam's new FHS environment and installed
  sniper pressure-vessel runtime completed 30 capped frames in 3.76 seconds
  including startup/exit, and the 2,000-frame release test in 2.20 seconds.
  A separate 32-bit libc executable loaded the correct MangoHud shim inside
  that runtime with `LD_LIBRARY_PATH` cleared. This checks injection/paths,
  not a 32-bit game's rendering or anti-cheat behavior.
- Alternating 20,000-frame runs took 3.06–3.19 seconds without MangoHud and
  3.31–3.91 seconds with the hidden, uncapped configuration. These short runs
  include initialization/teardown and software rendering; they establish
  measurable work and cannot predict AION's overhead or input latency.

AION's anti-cheat/Proton compatibility, actual 10 FPS presentation when
unfocused, focused frame times, tearing and direct scanout remain to be checked
on its restarted game process. No live game caps or focus were changed. No
Gamescope stage was added.

Upstream references:

- [MangoHud 0.8.3 configuration discovery](https://github.com/flightlessmango/MangoHud/blob/v0.8.3/src/config.cpp)
- [File watcher and reload timing](https://github.com/flightlessmango/MangoHud/blob/v0.8.3/src/notify.cpp)
- [Control socket commands](https://github.com/flightlessmango/MangoHud/blob/v0.8.3/src/control.cpp)
- [Limiter's zero-cap path](https://github.com/flightlessmango/MangoHud/blob/v0.8.3/src/fps_limiter.h)
- [Hidden overlay presentation path](https://github.com/flightlessmango/MangoHud/blob/v0.8.3/src/vulkan.cpp)
