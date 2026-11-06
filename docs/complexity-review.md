# Complexity review — 2026-11-05

Four independent GPT-6.1 Sol reviewers examined patches, sandbox infrastructure,
custom desktop packages, and Nix/host configuration. This reviews commit
`9f0f3c9`; the findings are suggestions, not implemented changes. The supervising
review checked key references, evaluated the locked upstream CLI versions, and
independently reproduced the TOML updater failures. No live desktop, Docker
concurrency, or full Orca restart acceptance test was performed.

The biggest savings come from deleting superseded implementations and deciding
which optional behaviors deserve their maintenance cost. Module rearrangement
would save much less.

## Recommended first batch

### 1. Remove the expired Claude manifest override

**Small effort; no intended feature loss.**

[The overlay](../overlays/default.nix#L25) says to remove the override once
nixpkgs-unstable reaches Claude Code 2.1.280. The locked input already provides
2.1.317. Importing the locked upstream package without local overlays confirmed
that version. Remove the override and its 91-line JSON manifest; retain the
ordinary unstable package import. Build and check the resulting CLI version
before deployment.

### 2. Finish the j2bar migration, then delete the retained desktop implementations

**Very large payoff; small deletion effort after live acceptance.**

[Updating instructions](updating.md#L43) explicitly say the standalone effects
are no longer installed and remain pending desktop acceptance. The current
[desktop imports](../users/jesse/hyprland-desktop/default.nix#L2) omit the old
wallpaper module. Retained engine/controller/audio, wallpaper helper, hyprsheet
and hyprrecede package trees total about 4,112 lines, including tests, notes and
license material. The unused wallpaper module adds 73 lines. Separately, the
unreferenced overlay patch tree and retained hyprglass package contain 1,180
patch lines. These counts overlap neither each other nor the Orca patches.

Use j2bar's already integrated implementations and Git history for rollback.
Remove the old packages, exports, unused module, patches and obsolete update
instructions together. Package exports still require evaluation, but the
[checks](../flake/checks.nix#L20) filter package builds by installed packages;
do not assume every retained package is built in CI.

Also finish deploying the replacement itself: the [flake input](../flake.nix#L33)
and lock point to `file:///home/jesse/projects/j2bar`, while the
[module](../hosts/common/optional/j2bar.nix#L10) relies on personal settings and
disables autostart for manual local builds. This creates a separate reproducibility
problem: CI checks out only this repository, and the
[VM instructions](mac-vm.md#L10) require copying the other checkout. Prefer a
reachable pinned source, declared j2bar settings and the module-owned service;
use a local `--override-input` for development. [Nix documents that mechanism](https://nix.dev/manual/nix/2.31/command-ref/new-cli/nix3-flake.html).
This gives up implicit deployment of the personal checkout/manual executable.
Verify fresh-machine/CI evaluation and one correctly configured shell process
at login. Publishing a new remote is a separate action, not part of this review.

**Loss:** standalone old CLIs and convenient in-tree rollback. Do not remove
them before checking effects, chooser placement, wallpaper pause/lock/hotplug,
audio restoration, and representative native/Proton games. The old game engine
has a [separate acceptance reminder](game-latency.md#L191).

### 3. Replace the handwritten hook TOML updater

**Small effort; no intended behavior loss; confirmed defect.**

[prepare-orca-hooks.py](../pkgs/agent-sandbox/prepare-orca-hooks.py#L36) first
parses TOML structurally, then edits it with line scanning, regular expressions
and manually emitted tables. Both valid indented tables and inline tables were
reproduced failing with `missing trusted_hash`.

Use `tomlkit` structural updates for `hooks.state`, retaining `enabled` and
unrelated settings. The repository already uses this dependency. This can
remove roughly 30–40 lines of format-specific handling. Test indented/inline
tables, disabled hooks, hash updates and idempotency. [TOML Kit documentation](https://tomlkit.readthedocs.io/en/latest/)
describes its preservation of formatting and comments.

### 4. Let existing tools do the small utilities' work

**Small effort; mostly equivalent behavior with focused verification.**

- [markdown-to-pdf](../pkgs/markdown-to-pdf/markdown-to-pdf.sh#L27) hand-parses
  Mermaid fences despite already depending on mermaid-cli. Replace that loop
  with its [documented Markdown transformation](https://github.com/mermaid-js/mermaid-cli#transform-a-markdown-file-with-mermaid-diagrams),
  keeping the existing Puppeteer and plain-SVG-label options and Pandoc step.
  The present loop silently drops the remainder after an unterminated diagram.
  Test multiple/no diagrams, malformed fences and relative images; upstream
  promises basic Markdown support, not full CommonMark equivalence.
- [wifi-connect](../pkgs/wifi-connect/wifi-connect.sh#L51) scans and parses
  networks, starts a supplicant, polls association and runs DHCP independently.
  On hosts already using NetworkManager, replace it with `nmcli --ask` or
  `nmtui`. [NetworkManager](https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/nmcli.html)
  also supports `connection add ... save no` for an in-memory profile.
  **Loss:** the exact numbered menu and operation without NetworkManager.
  Ordinary `wifi connect` persists a profile: preserve reboot-forgetting
  explicitly or choose to give it up. Do not enable another daemon on hosts
  that do not otherwise need it merely to eliminate this script.

## Larger simplifications worth choosing deliberately

### 5. Use stock Orca colors and an opaque titlebar

**Large payoff; small effort; visible behavior change.**

The [Orca patch list](../pkgs/orca-ade/package.nix#L56) includes a 524-line
Catppuccin patch and 139-line glass patch: 663 patch lines solely for appearance,
plus related update/rebase instructions. Use the stock dark application/editor
theme and retain the existing Catppuccin terminal setting.

**Loss:** exact application/editor palette matching and blurred titlebar.
This changes the documented design preference; it is not a claim that upstream
already provides equivalent full-application theming. Check a normal window,
editor and terminal after removing the patches and translucency setting.

### 6. Install Discord presence as an ordinary Orca plugin

**Medium payoff; small-to-medium migration; loses fully declarative installation.**

[The package](../pkgs/orca-ade/package.nix#L101) adds two core plugin
bundling/preapproval patches (112 lines), patches compiled plugin JavaScript,
and rewrites the bundled plugin index/hash. The plugin documents a normal
[Git/catalog installation workflow](https://github.com/jondmarien/orca-discord-presence)
and generic privacy is already its default.

Install and approve the plugin normally, then delete that packaging and consent
special case. **Loss:** automatic installation/approval, package-controlled
plugin pin and custom “Working in Orca ADE” wording. The current upstream
identity changed from `chron0.discord-presence` to `jondmarien.discord-presence`;
check migration and avoid two installed copies. Validate arRPC/browser presence
and privacy settings.

### 7. Make nested Hyprland a specialist mode, or remove it

**Large runtime simplification; medium effort.**

The sandbox [entrypoint](../pkgs/agent-sandbox/entrypoint.sh#L61) starts the
primary Sway display plus a second Sway and nested Hyprland. The extra desktop
requires an Aquamarine patch, supervisor/backoff, instance/socket discovery and
a second VNC surface. Removing the replica can delete roughly 230–250 lines.

**Loss:** testing Hyprland plugins/configuration with host-like appearance in
every coding sandbox. Keep primary Sway for ordinary GUI work. Check screenshots,
input, Playwright/Chromium, Xwayland and VNC. Making the replica opt-in reduces
runtime cost; merely moving the same code into another package does not reduce
the amount of maintained code.

### 8. Choose one sandbox launch architecture

**Medium payoff; medium effort; acceptance gate required.**

Direct per-harness containers coexist with [SSH execution hosts](../users/jesse/agent-sandbox.nix#L14),
SSH keys, startup polling and environment serialization into `sshd_config`.
Choosing direct launches alone could delete roughly 120–150 lines plus cleanup
special cases and documentation.

**Loss:** SSH clients/execution hosts connecting to these containers. The
[direct-launch documentation](agent-sandbox-orca.md#L68) still calls recognition,
history and resume experimental. Prove status, session history, full Orca
restart/resume, cancellation and cleanup before removing the fallback. The
earlier source-level resume check is not that live acceptance test.

### 9. Drop two optional sandbox conveniences

**Medium payoff; low-to-medium effort; independent choices.**

- [Steam integration](../pkgs/agent-sandbox/sandbox-steam.py#L1) copies manifests,
  rewrites login/update state and overlays Proton/runtime directories. Removing
  sandbox gaming saves roughly 145–165 lines plus instructions. **Loss:**
  launching installed host Steam games inside coding containers. Check which
  extra runtime allowances become unnecessary; other GUI tools may still need
  some of them.
- [Host clipboard mirroring](../pkgs/agent-sandbox/agent-sandbox.sh#L200)
  requires watchers, shared state files, inotify, `wl-copy` and cleanup. Orca
  already places image attachments under shared `/tmp/agent-media`. Using only
  attachments could remove roughly 90–110 lines and background processes.
  **Loss:** automatic host image clipboard contents in arbitrary sandbox GUI
  applications. Test attachment pastes in each harness.

### 10. Use explicit per-game GameMode launch options

**Medium payoff; medium migration; loses automatic coverage.**

[gaming.nix](../hosts/home/gaming.nix#L3) builds patched automatic clients for
two architectures, constructs a preload tree, repairs search paths and filters
Steam processes. Replace this with upstream's
[`gamemoderun %command%`](https://github.com/FeralInteractive/gamemode#requesting-gamemode),
combined with `j2bar game-run` where appropriate.

**Loss:** games without launch options no longer automatically register with
GameMode. Keep daemon policy and treat the separate I/O-priority patch
independently. Test representative native and Proton titles.

## Implementation fixes that also reduce complexity

### 11. Let Docker allocate published host ports

The [port allocator](../pkgs/agent-sandbox/agent-sandbox.sh#L372) probes ports
and holds a lock through `docker create`, then unlocks before `docker start`.
Its comment claims create reserves published ports. Docker's
[API documentation](https://github.com/moby/moby/blob/master/api/docs/v1.24.md)
describes allocation at start, leaving a concurrent-start gap outside the retry
loop.

Use loopback-only ephemeral publications such as `127.0.0.1::5900` and inspect
`docker port` after startup. [Docker documents ephemeral publication](https://docs.docker.com/get-started/docker-concepts/running-containers/publishing-ports/).
This removes the probe/lock/retry subsystem, roughly 30–40 net lines depending
on URL reporting. **Loss:** predictable low-numbered ports. Coordinate startup,
foreground attachment and URL discovery; test concurrent starts, failure,
Ctrl+C and loopback binding. This was a static/documentation finding, not a
locally reproduced Docker race.

### 12. Give managed Codex settings one source of truth

[Unreal startup](../pkgs/agent-sandbox/unreal-sandbox.py#L47) rewrites the shared
Codex TOML on every container start while other configuration writers can be
active. Ghidra already uses [launch-time overrides](../pkgs/agent-sandbox/package.nix#L189).
Use the same mechanism for Unreal, removing `sync-harnesses`, its startup path
and associated preservation test: about 45–55 lines.

**Loss:** the managed Unreal entry appearing physically in the persistent TOML;
the wrapped process still receives it. Verify effective MCP settings and a live
Unreal connection. Atomic replacement prevents partial files, not lost updates
between independent read/modify/write cycles.

### 13. Use normal application close behavior

[actions.lua](../users/jesse/hyprland-desktop/hyprland/actions.lua#L48) scans
windows and layers to infer process ownership, then sends SIGTERM before the
normal close request. Bind the built-in close action directly and optionally
keep process termination as a separate explicit shortcut.

**Loss:** closing an application's last visible window automatically terminates
its background process. This removes process-lifetime inference and lets apps
handle ordinary shutdown. Test editors with unsaved work, multiwindow browsers
and tray applications. [Hyprland dispatcher documentation](https://wiki.hypr.land/configuring/core/dispatchers/)
distinguishes graceful close from process signaling.

### 14. Bound diagnostic work as a whole

[game-latency-check](../pkgs/game-latency-check/game-latency-check.sh#L356)
can execute a separate timeout/ionice probe for each of up to 4,096 threads.
Per-probe timeouts do not bound total duration, and windows sharing a PID repeat
inspection. Keep the one-shot scheduling snapshot, deduplicate PIDs, and make
exhaustive I/O-priority checks explicit or impose a total deadline.

**Loss:** exhaustive per-thread I/O detail in the default output. Test a
many-thread process and two windows with the same PID. No timing benchmark was
performed in this review.

### 15. Replace Codex's settings merger with native system defaults

**Medium effort; removes a second configuration-management mechanism.**

[The Codex module](../users/jesse/codex/default.nix#L63) generates two settings
files, disables the usual Home Manager config link, and activates a
[custom recursive merger](../users/jesse/codex/merge-settings.py#L8) against host
and sandbox writable files. Deleted managed keys remain behind; the writer also
unlinks the current file before writing its replacement.

[Current OpenAI configuration documentation](https://learn.chatgpt.com/docs/config-file/config-basic)
describes `/etc/codex/config.toml` as Unix system defaults below writable user
configuration. Put the three defaults there, preserve writable user trust/state,
and remove the merger and activation reconciliation. **Loss:** Nix switches
would no longer force the chosen model over a saved personal choice. Existing
generated user defaults need a one-time migration or they mask system defaults.
Verify support in the locked CLI, CLI/Orca precedence and the sandbox's system
config mount. An immutable user config symlink is not an equivalent replacement.

### 16. Drop Dolphin's custom cosmetic transformation pipeline

**Medium payoff; small effort for icons; visible behavior change.**

[Dolphin already uses Catppuccin Papirus folders](../users/jesse/dolphin/default.nix#L8),
then adds a [254-line SVG recoloring engine](../users/jesse/dolphin/papirus-catppuccin.py#L1)
with color conversion and gamut handling. Use the existing theme directly and
delete the custom MIME-icon transformation and `icons.nix`.

Independent further cuts: use the stock Kvantum theme instead of the
[90-line glass transformation](../users/jesse/dolphin/kvantum-glass.py#L5), and
choose an existing font with suitable metrics instead of
[rewriting a font](../users/jesse/dolphin/view-font.nix#L1).
**Loss:** custom MIME-icon colors, optionally glass and the SF view font. Check
icons, thumbnails, view spacing and D-Bus launch. Retain functional Open With
menu setup and KIO/thumbnail plugins.

### 17. Use one package inventory

**Small effort; modest but recurring maintenance saving.**

[pkgs/default.nix](../pkgs/default.nix#L12) discovers package directories.
[flake.nix](../flake.nix#L104) repeats every package name, and
[checks.nix](../flake/checks.nix#L24) imports the discovered set again to assert
that the lists agree. Export the discovered packages filtered by platform
availability. Consider removing checks that select installed package outputs
already included in the host build closure; retain independent tests and decide
standalone package coverage explicitly.

**Loss:** an explicit export allowlist and redundant named check entries.
Compare exported names and check derivations on both architectures before
changing the inventory. This is secondary to deleting obsolete packages.

### 18. Stop maintaining an htop fork for plain h/j/k/l

[The package](../pkgs/htop-vim-navigation/package.nix#L3) adds a version gate
and patch for eight key translations. Stock htop already has arrows and Alt
navigation; [upstream source](https://github.com/htop-dev/htop/blob/main/ScreenManager.c)
contains the latter. Use stock htop and remove the package, patch, exports and
related update instructions. **Loss:** unmodified h/j/k/l navigation. Small
absolute saving, but also one fewer package version gate.

## Separate correctness findings

- **First-launch Codex hook trust can be skipped.**
  [Direct launch prepares hooks](../pkgs/agent-sandbox/agent-sandbox-exec.sh#L50)
  before the launcher seeds Codex config. The
  [preparer returns early](../pkgs/agent-sandbox/prepare-orca-hooks.py#L83)
  if that config is missing. Seed before preparing, and test an empty sandbox
  home. This finding is based on execution order.
- **Configured Codex agents are not mounted.**
  [Definitions are installed in `.codex/agents`](../users/jesse/codex/default.nix#L39),
  but the [sandbox mount list](../pkgs/agent-sandbox/agent-sandbox.sh#L110)
  omits that directory. Include it and test Laravel/Rust agent discovery.

## Changes not justified by this review

Do not remove functional Claude hook routing, shared-media routing, Orca resume
integration, the Ghidra stdout fix, or the first-frame tearing patch merely
because they are custom. No equivalent replacement was established.

A static Hyprland float rule does not preserve the current move-into-workspace
and restore-previous-state behavior. A generic FPS limiter does not establish
parity with focus-aware game policy. The old audit's module/default-cleanup
findings also need rechecking against the current tree rather than automatic
implementation.
