# Updating

Most inputs follow a branch and move with `nix flake update`. A few are pinned
to an exact `rev` in `flake.nix`, or have to move together with something
else. `nix flake update` doesn't move a pin like that, and bumping it by hand
without its partners gives a build error at best and a broken desktop at worst.

This file is the reference for every update rule, and `CLAUDE.md` imports it.

## Routine update

```sh
nix flake update
nix flake check        # builds every host for this machine's system
nh os switch --ask     # shows the package diff and asks before activating
```

The [update workflow](../.github/workflows/update.yml) runs `nix flake update`
every week, runs `nix flake check` against the new lock on each system, and
opens a pull request only when every check passes.

`home` runs up to four Nix builds with 8 cores each, inside nix-daemon's 24G memory limit. The sandbox's Blender also uses
`WITH_CYCLES_CUDA_BUILD_SERIAL`, because CUDA's split compiler otherwise starts
extra threads alongside the regular compiler jobs.

## Inputs that move as a unit

### The release

`nixpkgs`, `home-manager` and `catppuccin` all follow
branches for the same NixOS release. To change release, move all three to the new
release's branches in one commit. A new release can also break the hy3dgen and
Eisvogel pins in [Pins outside `flake.lock`](#pins-outside-flakelock), which
depend on its Python and TeX Live.

Firefox's Catppuccin theme is a copy of the catppuccin port's mocha/mauve
theme in [`users/jesse/catppuccin-firefox/`](../users/jesse/catppuccin-firefox),
because the port builds it during evaluation. When a catppuccin bump changes
the port, regenerate it with
`jq '{mocha: {mauve: .mocha.mauve}}' "$(nix build --no-link --print-out-paths --impure --expr '(builtins.getFlake (toString ./.)).inputs.catppuccin.packages.x86_64-linux.firefox')/themes.json"`.

`nixpkgs-unstable` doesn't follow the release. It supplies `pkgs.unstable` for
the few packages that need something newer.

### Hyprland

`nixpkgs-hyprland` pins the compositor, portal and screenshot freezer (`hyprpicker`)
together. Hyprland 0.57 changed screencopy transforms; the release nixpkgs'
hyprpicker 0.4.7 rotates frozen content incorrectly on portrait outputs. The
coupled 0.4.8 uses ext-image-copy-capture instead. Grimblast's wrapped PATH must
use that coupled picker, including for `--freeze` region selection. See
[the upstream regression](https://github.com/hyprwm/Hyprland/discussions/16707)
and [the capture-protocol migration](https://github.com/hyprwm/hyprpicker/commit/7bb69515f2c4).

The `tohru` input's
plugin (focus dips, title bars, chooser sheets and launcher recession) is built
against the exact host Hyprland package, and its own `hyprland-nixpkgs` input
follows `nixpkgs-hyprland`. The desktop assertion in
`users/jesse/hyprland-desktop/hyprland/default.nix` and the plugin package
require 0.57.2. The desktop runs nixpkgs' Hyprland unpatched: 0.57 includes the
first-frame tearing fix (Hyprland PR 16572) that `home` used to carry as a patch.

To upgrade, move `nixpkgs-hyprland` to the revision Tohru's
`hyprland/UPSTREAM.md` reviewed, then `nix flake update tohru`. Review the
plugin in the Tohru repository against the same pinned headers; a successful
compile alone does not establish compatibility. Check `look.lua` against any
config keys or animation leaves the plugin renames, and its Lua configuration
against compositor API changes. Check chooser opening/closing from Firefox on
both normal and rotated monitors, title-bar maximize/unload, launcher recession
without damage artifacts, and live tearing in a game, including cursor/DRM
restrictions. Rebase `pkgs/agent-sandbox/aquamarine-nested.patch` against the
coupled Aquamarine, verify `NESTED-1` with the plugin loaded, update version
assertions, and build `home` before activation.

Also check Super+P's frozen selection on portrait and landscape outputs: the
overlay must retain each output's orientation, and the saved/copy image must
match the selected area. Include a selection spanning both outputs.

### Tohru

The `tohru` flake input (`github:malinoskj2/tohru`) supplies the shell, its Home
Manager module and the compositor plugin. `users/jesse/hyprland-desktop/tohru.nix`
enables it with its systemd user services (bar, session menu, launcher and the
only notification daemon) and sets `bar.preferred_output` to the main monitor.
The flake's own package is used, so its pinned nixpkgs keeps the Pleamar build
cached; it only exports x86_64-linux, and other hosts run without a shell. Update
with `nix flake update tohru`, then build `home`.

Effect settings live in `hyprland/look.lua`. The plugin registers its animation
leaves only once it is loaded, which at startup is after the configuration has
run, so `look.lua` sets them through `pcall` and again on `hyprland.start`.

The rest of the desktop is standard Hyprland tooling:

- hyprlock locks, through `session-lock` (`lock.nix`), which also sets logind's
  `LockedHint` so `wallpaper-autopause` pauses behind it.
- hypridle keeps the old timeouts: lock after 30 minutes, screens off a minute
  into a lock, suspend after 2 hours or 90 minutes into a lock, and lock before
  sleep. There is no pre-action fade and no caffeine toggle.
- hyprpolkitagent is the only polkit agent.
- Super+P runs `grimblast --notify --freeze copysave area` into
  `~/Pictures/Screenshots`.
- Video wallpapers run from the `wallpaper-outputs` and `wallpaper@` units.

j2bar's game engine and workspace-5 audio worker are gone; games run without a
limiter. `~/.config/j2bar` and j2bar's state are left in place for rollback.

### Firefox

`nixpkgs-firefox` is an exact nixpkgs commit, and `wavefox` is the WaveFox
release for that Firefox major version. Move them together. Then open Firefox
and check what [`users/jesse/firefox.nix`](../users/jesse/firefox.nix) depends
on: the Nova setting, the imported WaveFox CSS, the cascade-layer order and the
transparent chrome. Since Firefox 159 it also needs the local horizontal-tab overrides for
the inset rounded content frame, navigation spacing, hidden sidebar toggle,
fallback tab icon and translucent selected tab. Check normal, maximized and
fullscreen windows when moving these.
A Firefox or WaveFox UI change can break any of them
without a build error.

[`users/jesse/arrpc/`](../users/jesse/arrpc) also adds an AutoConfig file to
Firefox that registers a window actor on discord.com, which runs arRPC's bridge
mod from one pinned arRPC commit in the page. With arRPC running, open
discord.com and check that `journalctl --user -u arRPC` logs `web connected`
once, without a Local Network Access prompt, and that an RPC client's activity
shows on your profile. Firefox changes to AutoConfig, `registerWindowActor`
(including `safeForUntrustedWebProcess`) or the `LocalNetworkAccess` policy
fail silently. To move the bridge mod, change the commit in its URL and refresh
its hash, then rebase
[`bridge-mod.patch`](../users/jesse/arrpc/bridge-mod.patch). It matches
Discord's Flux dispatcher by its class's methods, because Discord's i18n
messages Proxy answers every property and wins upstream's duck-typed search.
That failure is silent too: the activity reaches the tab and shows nowhere.

### sops-nix

`sops-nix` follows its default branch with the release's nixpkgs, and moves
with `nix flake update`. [Secrets](secrets.md) depend on its
`useSystemdActivation` unit, `sops-install-secrets.service`, its
`system.build.sops-nix-manifest` and the manifest's JSON fields:
`hosts/common/optional/secret-store.nix` gives the unit an `ExecCondition`, so
a missing file or key withdraws everything instead of failing the switch, and
replaces its `ExecStart` with a wrapper that deploys only the secrets present
in the file. After an update, build `checks.x86_64-linux.secrets-vm` and
`secrets-eval`: they boot without the file, add, rotate and remove secrets
with `secret`, check the decrypted files' owners and modes, and check that the
declaration rules fail evaluation. A renamed option, a moved unit or a changed
manifest fails them.

## Inputs pinned to a commit

### `apple-fonts`

[Lyndeno/apple-fonts.nix](https://github.com/Lyndeno/apple-fonts.nix) records
hashes of Apple's `.dmg` downloads, but Apple replaces those files in place. A
machine that doesn't already have a file then fails with a hash mismatch, and
so does CI. To fix it, move the pinned commit to a recent one (upstream
refreshes the hashes daily), run `nix flake lock`, and rebuild the affected
font packages.

### `nixos-hardware`

This input supplies the Raspberry Pi 4 kernel and firmware handling for `pi`.
Treat a bump as a hardware change and test it on the device.

## Pins outside `flake.lock`

- **NVIDIA driver on `home`.**
  [`hosts/home/nvidia.nix`](../hosts/home/nvidia.nix) builds a driver from
  NVIDIA's New Feature Branch, newer than the release's default. The version
  and every `sha256` change together. Copy them from the `new_feature` entry of
  `pkgs/os-specific/linux/nvidia-x11/default.nix` in nixos-unstable. Once
  NVIDIA's production branch passes the pinned version, move back to the
  `production` entry. 615 hitches the desktop when the memory clock changes;
  check a new driver against [nvidia-memory-clock.md](nvidia-memory-clock.md).
  The `cuda` dev shell in [`flake/devshell.nix`](../flake/devshell.nix) takes the
  `cudaPackages` matching the CUDA version `nvidia-smi` reports for the driver;
  move it with the driver, then compile and run a small kernel in it.
- **claude-code.** The `unstable` overlay in
  [`overlays/default.nix`](../overlays/default.nix) builds `nixpkgs-unstable`'s
  claude-code with the release's `alsa-lib`: the wrapper puts it on
  `LD_LIBRARY_PATH`, every command Claude runs inherits that, and unstable's
  build needs a newer glibc than release programs that load libasound, such as
  mpv. To run a release unstable doesn't have yet, give the override a
  `manifest` from
  `https://downloads.claude.ai/claude-code-releases/<version>/manifest.zst.json`,
  and drop it once `nixpkgs-unstable` catches up.
- **Antigravity CLI.** [`pkgs/antigravity-cli/`](../pkgs/antigravity-cli)
  builds the `agy` release it names on `pkgs.unstable`'s derivation, with its
  self-updater off. To move it, read the version from
  `https://storage.googleapis.com/antigravity-public/antigravity-cli/latest`,
  then copy the build ID and each Linux platform's `sha512` from
  `<version>/manifest.json`. Drop the override once `nixpkgs-unstable` catches
  up. Orca reads agy's hook payloads and transcripts, so check that an agy
  session in a sandbox shows working and done in Orca's sidebar and resumes
  in a sandbox after Orca restarts.
- **Betterleaks.** [`pkgs/betterleaks-push-gate/`](../pkgs/betterleaks-push-gate)
  takes `betterleaks` from `pkgs.unstable`, since the release's build is far
  behind and new rules matter. The global pre-push scan
  ([git-push-gate.md](git-push-gate.md)) is a config-based hook, which needs
  Git 2.54 or newer; an older git ignores it silently. After a git, gh or
  Betterleaks update, check the hook still refuses a commit with a fake token
  and allows a clean push to a local bare remote, that `git push --no-verify`
  is refused, and that `gh`'s refused commands in `gh.sh` still match how
  `gh` pushes (`git/client.go`'s `Push` runs `git` from `PATH`) and which
  commands write through the API.
- **Strata.** [`pkgs/strata/`](../pkgs/strata) builds one Niko1221/Strata
  release tag (the commit it points at) from source for `qwen-prompt --moe`
  and `qwen-opencode --moe`: the `strata` engine for the RTX 5090 only, with
  CUDA 13.0, which Strata pins because 13.2 miscompiles its sm_120 kernels, and
  its Python server and preparation tools from `terminal/`. Inkling, Hy4 and the
  vision encoder aren't built. To move it, change `version`, `rev` and the
  hash, and check the release's `tools/nix/flake.nix` and
  `terminal/requirements.txt` for a new CUDA or Python requirement. The pack
  in `~/.cache/qwen-prompt/strata/` records the Strata build it came from, so
  the next `--moe` launch rebuilds it for a new one. Then run `qwen-prompt --moe` for both models and
  check that the engine log reports the resident low-RAM mode, the MTP draft
  layer and the n-gram table read from the second shard.
- **rust-lints.** [`pkgs/rust-lints/`](../pkgs/rust-lints) builds a Dylint
  library against one nightly from the `rust-overlay` input. `nightlyDate`,
  `dylintVersion` and `clippyUtilsVersion` move together: take the newest
  `clippy_utils` release, the nightly its README names, and the Dylint release
  that supports it. Change `channel` in `lints/rust-toolchain.toml` and the
  `clippy_utils`, `dylint_*` and `dylint-driver` versions in both crates'
  manifests, refresh both lockfiles with that nightly's `cargo`, then refresh
  the crate and vendor hashes. `dylint_driver`'s build script reads
  `clippy_utils/src/sym.rs` from a Clippy checkout; the package fakes one from
  the pinned crate, so rustc API changes surface as compile errors in
  `lints/src`. Build `checks.<system>.rust-lints-library` (UI tests) and
  `rust-lints-fixture` (the runner on a stable project, offline), then run
  `rust-lints` on a real workspace.
- **ts-lints.** [`pkgs/ts-lints/`](../pkgs/ts-lints) pins exact npm versions
  in `package.json`. Keep `typescript` on the newest 6.0 release until
  typescript-eslint's peer range and vue-tsc accept TypeScript 7, which has no
  JavaScript API. Bump the rest together, run `npm install` there, refresh
  `npmDepsHash`, and remove the local `node_modules`. The build runs the rule
  tests and the runner on its fixtures. `typescript-eslint`'s `strict*` presets
  and `eslint-plugin-vue`'s `recommended-error` can gain rules in a minor
  release, so run `ts-lints` on a real Vue project afterwards and compare the
  rule counts.
- **htop.** [`pkgs/htop-vim-navigation/`](../pkgs/htop-vim-navigation) asserts
  the htop versions its patch was checked against. If a nixpkgs update trips
  it, re-check the patch next to it and add the new version.
- **mpvpaper-vk.** [`pkgs/mpvpaper-vk/`](../pkgs/mpvpaper-vk) plays the video
  wallpapers. It is nixpkgs' mpvpaper drawing through Vulkan, built against a
  private patched mpv so the system mpv stays stock, and an mpv update
  rebuilds it from source.
  [`libmpv-vulkan.patch`](../pkgs/mpvpaper-vk/libmpv-vulkan.patch) adds a
  `vulkan` libmpv render API that creates the device with mpv's own
  `mppl_create_vulkan` and hands it to the client. It also unmaps Vulkan hwdec
  frames after each render in the `gpu` renderer, which otherwise holds the
  `AVVkFrame` lock and deadlocks the decoder on loops, seeks and shutdown.
  [`mpvpaper-vulkan.patch`](../pkgs/mpvpaper-vk/mpvpaper-vulkan.patch) replaces
  mpvpaper's EGL path with libplacebo swapchains on that device and defaults
  `gpu-hwdec-interop` to `vulkan`, because libmpv otherwise loads every interop
  at startup, and the CUDA one holds about 1 GB of VRAM. Rebase the patches when
  mpv or mpvpaper moves. Then play a wallpaper and check that `hwdec-current`
  is `vulkan`, playback continues past the loop point, pause and seek work,
  SIGTERM exits promptly and `nvidia-smi` shows about 250 MiB per instance.
- **Steam GameMode.** [`hosts/home/gaming.nix`](../hosts/home/gaming.nix)
  patches Steam's 32-bit and 64-bit GameMode libraries with
  [`steam-gamemode.patch`](../hosts/home/steam-gamemode.patch). It gates automatic
  registration on a nonzero Steam game ID, prevents forked children from
  unregistering their parent, and handles disconnected D-Bus calls without
  aborting. Review the patch and its version assertion when updating GameMode;
  check Steam startup and automatic registration for native and Proton games.
  The preload uses a store-path directory selected by the loader's literal
  `${PLATFORM}` token for 32-bit/64-bit libraries; verify it inside Steam's
  pressure-vessel container, where `/run/host/lib` symlinks can resolve into
  the inner runtime instead. The automatic loader's RUNPATH must include its
  companion `libgamemode.so` directory because Steam replaces LD_LIBRARY_PATH.
  Test an actual automatic registration request for each architecture, not just
  whether `libgamemodeauto` appears in process mappings. After activation, check
  that the user daemon is running the new binary; its security-wrapper ExecStart
  path stays constant, so the unit has an explicit package restart trigger.
  The desktop daemon also carries
  [`gamemode-ioprio.patch`](../hosts/home/gamemode-ioprio.patch): unset I/O
  priority must be interpreted from CPU niceness, distinct from explicit
  best-effort priority zero. Check boost/restore across threads and preservation
  of custom priorities when updating the 1.8.2 version assertion.
- **Orca.** [`pkgs/orca-ade/`](../pkgs/orca-ade) builds one stablyai/orca
  release tag from source against `pkgs.unstable`'s Electron 43, Node 24 and
  pnpm 11. To move it, change `version`, then refresh the source hash and both
  pnpm dependency hashes (the root and `mobile/` lockfiles). Set
  `sourceCommit` to the commit the tag points at (`git ls-remote
  https://github.com/stablyai/orca 'refs/tags/v<version>^{}'`): the build pins
  official skill installs to it and upstream reads it from a git checkout.
  Since 1.4.225 every SSH and WSL host runs orcad from a deployment template
  with prebuilt addons for each remote target, which only upstream's release
  pipeline builds, so `passthru.orcadTemplate` extracts it from the release's
  amd64 `.deb`; refresh that hash too. Keep `electron_43`
  and `nodejs_24` on the majors the release's `package.json` names in
  `electron` and `engines.node`. Its `packageManager` is pnpm 12, which
  `nixpkgs-unstable` doesn't have yet, so `pnpm_11` builds it until `pnpm_12`
  lands. The Vulkan transcription backend also needs `vulkan-loader` during
  ELF fixup; discard Koffi's bundled musl variant on these glibc systems.
  The package build runs the sandbox launch, container indicator, theme and
  runtime tests before packaging. Tests the patches add on their own go in
  `nix-` files, so upstream can move or rewrite its own test files freely. Build the configured Home Manager package
  as well as the default package to check declarative settings and plugins.
  Maintain
  the data-only [`catppuccin/`](../pkgs/orca-ade/catppuccin) theme plugin. Its
  public app tokens and TextMate `tokenColors` cover the app, editor and Markdown;
  validate with `orca plugin validate pkgs/orca-ade/catppuccin --json` against
  the pinned release. Native `pluginAppThemeDark` and `editorThemeDark` select it,
  while the terminal keeps its built-in Catppuccin Mocha palette. Protected trust
  and approval colors remain in the narrowly scoped
  [`catppuccin-security.patch`](../pkgs/orca-ade/catppuccin-security.patch).
  Public themes cannot override private status/title colors, Monaco's individual
  widget/find colors, or force a sidebar surface over a saved Match terminal or
  Tinted preference; these now follow upstream behavior. Nix syntax's custom
  grammar patch was removed without a replacement. Rebase
  [`glass-titlebar.patch`](../pkgs/orca-ade/glass-titlebar.patch) when Orca
  changes its top-bar layout. It relies on the `windowMaterial = "translucent"`
  setting in [`features/desktop.nix`](../users/jesse/features/desktop.nix) for
  an alpha-capable window, and keeps that material on for Linux in
  `resolveWindowMaterial`, which upstream turns off unless terminals are
  translucent; confirm only the titlebar band shows compositor blur. That band
  is `--app-header-height`, 36px unless Linux tiling window mode shrinks it to
  the tab row. Rebase
  [`claude-hooks.patch`](../pkgs/orca-ade/claude-hooks.patch): it keeps Orca out
  of the Nix-managed `~/.claude/settings.json` by writing its hooks to
  `~/.orca/agent-hooks/claude-settings.json` and passing that file with
  `--settings`. Claude account profiles, each with its own
  `CLAUDE_CONFIG_DIR`, share that file. Over SSH it writes the same file on the
  remote, which the agent sandbox's `claude` wrapper loads; the remote's orcad
  comes unpatched from the template, so it doesn't add the flag itself.
  Upstream Claude launches move often, so check every one still gets the flag,
  not just the build. Also rebase
  [`open-video-externally.patch`](../pkgs/orca-ade/open-video-externally.patch),
  which opens a clicked video path with the system default (mpv) instead of
  Orca's editor,
  [`pending-below-main.patch`](../pkgs/orca-ade/pending-below-main.patch),
  which puts a workspace being created below its project's main worktree
  instead of above it,
  and [`approved-plugins.patch`](../pkgs/orca-ade/approved-plugins.patch), which
  treats the plugins in `approvedPlugins` as consented. Rebase
  [`host-git-guard.patch`](../pkgs/orca-ade/host-git-guard.patch), which sends
  Orca's `git`, `gh` and `glab` through the
  [host Git wrapper](agent-sandbox-orca.md#orcas-own-git-on-the-host), and check
  that no new code spawns them without `resolveCommand` in
  `wsl-command-resolution.ts`:
  `rg -n "(spawn|execFile)(Sync)?\(\s*'(git|gh|glab)'" src --glob '!*.test*' --glob '!*.spec.ts' --glob '!*-ssh-shim.cjs'`
  should list nothing. A new Git option that runs a program goes in
  `host-git.sh` and its test. The wrapper runs `pkgs.unstable.git`, since it
  switches hooks off per event, which needs Git 2.56; after a Git update,
  compare its `events` list with githooks(5) and check new
  commands against its host list, which must only hold commands that need the
  network or the credential helpers and never read attributes, format commits
  or start help. The jail hides worktrees outside the repository, so also
  check that no newly jailed command prunes or repairs other worktrees; the
  wrapper skips `worktree prune`, `gc` and `maintenance`, and turns off
  automatic housekeeping everywhere. A new subcommand that starts gc or
  maintenance needs the same treatment. The jail is bubblewrap, at least
  0.9 for `--bind-fd`, so
  `checks.orca-host-git` runs it in the build. Native per-repository
  `orca repo set-base-ref` replaces the automatic local-default fallback patch:
  `orca.localBaseRefs` seeds `main` only for an existing local `/home/jesse/nix`
  repo with no persisted choice and an existing local branch. Custom choices,
  remote repos and other paths are untouched; a state marker preserves later
  resets to inherited defaults. New repos and stale refs use upstream fallback
  behavior rather than automatically preferring their local default. Rebase
  [`agent-resume-wrapper.patch`](../pkgs/orca-ade/agent-resume-wrapper.patch),
  which runs the Claude, Codex, Muse and Antigravity resumes Orca starts when
  it reopens through `agentResumeWrapper` as `<wrapper> <agent> <args>`, for
  local workspaces only. `home` sets it to
  `agent-sandbox-resume` (`orca.agentResumeWrapper` in
  [`agent-sandbox.nix`](../users/jesse/agent-sandbox.nix)), which resumes in a
  sandbox the sessions a sandbox started; other hosts leave it unset. Upstream
  may add another automatic resume path besides the pane cold restore. The
  build stages jondmarien/orca-discord-presence and Etherll/orca-usage-insights
  outside the official launch bundles, under `share/orca-ade/plugins`. They keep
  their pinned commits and declared `chron0.discord-presence` /
  `etherll.usage-insights` identities. In 1.4.268 local-folder installs preserve
  declared publishers; Git installs derive the publisher from the owner, which
  would change Discord's identity. Keep checking this compatibility on upgrades.
  The Home Manager `orca-declarative-setup` timer installs these folders through
  the native CLI after a runtime becomes available, including exact returned
  consent fingerprints for only these pinned plugins. It skips an already
  installed source, disabled plugins and development overrides. Disabled installs
  migrate after re-enabling; no data/settings or disable choices are removed.
  [`legacy-plugin-migration.patch`](../pkgs/orca-ade/legacy-plugin-migration.patch)
  temporarily exempts only the two former Nix bundle IDs from upstream retirement:
  otherwise startup deletes their storage and disable/settings state before the
  CLI can run. It also keeps these legacy entries marked third-party until they
  migrate. It changes no official bundle installation or retirement policy, and
  allows no new third-party bundles. Keep it until every existing profile has
  migrated; disabled profiles deliberately retain their old source until enabled.
  A generation change migrates to its new immutable store folder. Each plugin has
  an inert `nix-installation.json` naming that folder: native same-byte installs
  otherwise retain their previous provenance, causing a legacy bundle to remain
  bundled or a timer to repeatedly reinstall a changed source path. Native updates
  from a local folder keep that pinned source rather than following a catalog.
  Builds and activation do not contact Orca or start its UI. Inspect failures with
  `journalctl --user -u orca-declarative-setup` and retry with
  `systemctl --user start orca-declarative-setup` when the runtime is running.
  To move a plugin, change `rev`, refresh its hash and review the new source's
  fetches, spawns and writes. Existing `discordPresenceSettings` merging, URL/token
  fallbacks and the generic "Working in Orca ADE" detail remain unchanged.
  `usageInsightsSettings` becomes the
  manifest's setting defaults, and an unknown key fails the build. `home` adds
  the sandbox's Codex home there, since sandboxed Claude already shares
  `~/.claude/projects`. The `postPatch` also edits upstream source in place: it drops
  the AppImage's glibc floor check and its downloaded Node runtime, skips the
  Docker build of the Wayland clipboard helper, which `buildPhase` compiles
  instead, builds the provider exec helper and the journal file lock with the
  host compiler instead of Docker, and makes
  directories it uploads over SSH writable after they're extracted on the
  remote. Each uses `--replace-fail`, so a moved line fails the build; find
  where the new release does the same thing. Keep-awake now uses
  `globalSettings.keepComputerAwakeWhileAgentsRun` alongside other declarative
  settings, without a source default substitution. Structured sandbox Command
  overrides use `~/.orca/nix/bin/orca-sandbox-launch orca-sandbox <agent>`, accepted
  by the native literal parser; automatic resume routing is unchanged. The portable
  [`sandbox-launch.sh`](../pkgs/orca-ade/sandbox-launch.sh) strips the provenance
  marker, then preserves Darwin's first executable `sandbox-*` in PATH and Linux's
  `agent-sandbox-exec` selection, passing every remaining argument unchanged.
  Home Manager installs the local executable; the narrowly scoped
  [`sandbox-wrapper-deployment.patch`](../pkgs/orca-ade/sandbox-wrapper-deployment.patch)
  includes it in verified template artifacts, preserves its mode, and installs it
  into the remote user's same home-relative path before a POSIX orcad launch.
  This avoids relying on remote login PATH or Nix store paths. The template adds
  only that resource and its hash; its release runtime bytes remain unchanged.
  Test Darwin/Linux dispatch and a simulated local deployment on upgrades;
  actual SSH-host execution still needs an explicit runtime smoke test.
  `telemetryOptedIn` forces only
  `telemetry.optedIn` when a profile loads, since that block also holds the
  install ID and cohorts. Nothing is sent either way: telemetry needs the
  PostHog key and build identity that only upstream's CI compiles in, and
  this build and the release's orcad template both leave them unset; check
  that `orcad-server.js` still reads `ORCA_POSTHOG_WRITE_KEY` as an unset
  global. Crashpad keeps its dumps local. Then, in Orca:
  - connect a sandbox workspace over SSH and check that orcad deploys and its
    terminals open;
  - copy text from a terminal and the editor and paste it into another
    application, which goes through the Wayland clipboard helper;
  - check that a `claude` typed into an Orca terminal and one Orca launches
    both show working and done in the sidebar, with the running tool, locally
    and in a sandbox workspace over SSH;
  - on `home`, start `sandbox claude` and `sandbox codex` in a local
    workspace and a plain `codex` in another, quit Orca and stop its daemon,
    reopen it and check that both sandboxed sessions resume in new sandbox
    containers, the plain Codex resumes on the host, and an agent in a sandbox
    workspace over SSH resumes with its plain command;
  - on `home`, pick OpenCode in the new-worktree agent picker and check that
    it opens plain `opencode` in that repository's sandbox, since
    `agentCmdOverrides.opencode` relies on Orca treating a resolvable override
    as installed;
  - open a Claude chat tab (Settings → Experimental) and check that its
    `claude` process has `--settings`;
  - check the chat view, sidebars, tabs, popovers and status bar use Mocha, then
    open a file and a diff to check the Catppuccin Monaco theme;
  - run `orca-ide agent hooks status --json` and check that Claude reports
    `installed`;
  - click a video path in a chat tab and in a terminal, locally and in a
    sandbox workspace, and check that it opens in a floating mpv;
  - check that `~/.claude/settings.json` is unchanged and that a plain
    `claude` outside Orca has no Orca hooks;
  - check that Settings → Plugins lists Discord Rich Presence as Bundled and
    enabled without a consent prompt, and that Discord Presence: Show Status
    reports `connected=true` against arRPC with `detail=generic`;
  - check that Settings → Plugins lists Usage Insights as Bundled and enabled
    without a consent prompt, and that on `home` its panel lists the sandbox
    Codex folder as a source;
  - check that Getting started shows Enable Orca CLI as done. It only looks
    for the `orca-cli`, `orca-computer-use` and `orchestration` skills, which
    [`features/desktop.nix`](../users/jesse/features/desktop.nix) installs
    from the release's `skills/`, so a renamed or added skill leaves it undone;
  - check that Settings → Orchestration shows every detected agent covered,
    with no Review skill warning. Orca's bundled-skill plan only counts a real
    `~/.agents/skills/<skill>` folder holding exactly the release's `SKILL.md`
    (Codex reads it directly), with `~/.claude/skills` and
    `~/.gemini/config/skills` (Antigravity) linking to that folder; a link
    into the store reads as another owner's skill. So the activation copies
    each `SKILL.md` there, and the agent sandbox mounts that folder. If Orca
    moves a provider's skill folder (`skill-install-providers.ts`) or changes
    how it classifies a copy (`bundled-skill-classification.ts`,
    `bundled-skill-plan.ts`), follow it.
- **CoreCycler.** [`pkgs/corecycler/`](../pkgs/corecycler) builds one
  Daaboulex/linux-corecycler commit with the mprime, y-cruncher, stress-ng and
  stressapptest backends. nixpkgs fetches mprime from download.mersenne.ca,
  which serves an HTML page, so the package refetches the same archive from
  mersenne.org with nixpkgs' hash; drop the override once nixpkgs' URL works.
  To move CoreCycler, change `rev` and refresh its hash, and compare
  upstream's `flake.nix` for new runtime tools. Its NixOS module isn't used,
  because `home` already loads `ryzen_smu`; `hosts/home/corecycler.nix` carries
  its device-access rules. Run `corecycler doctor` after an update.
- **Eisvogel.** [`pkgs/markdown-to-pdf/`](../pkgs/markdown-to-pdf) typesets
  with the Eisvogel LaTeX template at `v3.4.0`. Eisvogel 3.5.0 moved from the
  `sourcesanspro` TeX Live package to `sourcesans`, which nixpkgs doesn't
  package yet. Once the release's `texlive` has `sourcesans`, move `rev` to the
  newest Eisvogel tag and refresh its hash. Then run `markdown-to-pdf` on a file
  with a code block, a table and a Mermaid diagram, and check the PDF's fonts
  and layout.
- **hy3dgen.** [`pkgs/hy3dgen/`](../pkgs/hy3dgen) builds one Hunyuan3D-2 commit
  for the agent sandbox. Its xatlas dependency is a prebuilt wheel, because the
  sdist needs a git submodule, and the wheel is `cp313`: it only loads while
  the release's `python3` is 3.13. When a release moves `python3`, replace the
  wheel's URL and hash with the matching `cp3xx` manylinux x86_64 wheel from
  `https://pypi.org/pypi/xatlas/json`, taking a newer xatlas if 0.0.11 has none.
  To move Hunyuan3D-2, change `rev`, refresh its hash and check that the
  `postPatch` that lets diffusers load its local pipeline still applies. Either
  way, build `hy3dgen`: its import checks load xatlas and the compiled
  extensions.
- **qwen3-tts-python.** [`pkgs/qwen3-tts-python/`](../pkgs/qwen3-tts-python)
  is Tohru's high-VRAM voice interpreter: hy3dgen's CUDA `torch-bin` scope with
  faster-qwen3-tts 0.5.4 and qwen-tts-hf as wheels. They need transformers
  5.15.1 or newer, whose import check wants safetensors 0.8, so both come from
  wheels until the release has them; `sox` is packaged from its sdist because
  the 25 Hz tokenizer imports it at load. To move faster-qwen3-tts, take its
  wheel and `requires_dist` from PyPI and adjust the overrides. Then load
  `voice-tomoko` under `gpu-run` with `generate_custom_voice_streaming` and
  speaker `kuroki_tomoko`, as Tohru's worker does.
- **pyghidra-mcp.** [`pkgs/pyghidra-mcp/`](../pkgs/pyghidra-mcp) is the Ghidra
  MCP server for Claude Code and Codex on the host and in the agent sandbox,
  run over stdio by its `ghidra-mcp` launcher. It is disabled by default in
  Codex; opt in with `codex -c mcp_servers.ghidra.enabled=true`. Claude Code
  does not register it by default; add it explicitly for projects that need it.
  It packages `ghidrecomp` inline. To move either, change `version` and refresh
  its hash, then rebase
  [`stdio-stdout.patch`](../pkgs/pyghidra-mcp/stdio-stdout.patch): ghidrecomp
  and Ghidra print to stdout, so in stdio mode the patch gives the MCP stream
  its own copy of stdout and points fd 1 at stderr. Check it by importing a
  binary, decompiling a function and running `gen_callgraph` over stdio, with
  nothing but JSON-RPC on stdout. LaurieWired's GhidraMCP needs the exact
  Ghidra version it was built for, which nixpkgs may not have.

## Background game FPS limiting

There is no background limiter since the move from j2bar to Tohru; see
[game-latency.md](game-latency.md#background-frame-limit). Preserve GameMode when updating.

## Things an update never touches

- `system.stateVersion` and `home.stateVersion` record each machine's install
  baseline, not the current release. Don't bump them during an update.
- Generated `hardware-configuration.nix` files come from the machine. Regenerate
  them there, and don't hand-edit them.

## General

- Flakes only see files Git tracks, so `git add` new files before evaluating.
- Every host evaluates without `--impure`. Keep it that way.
- The repository is public, so keep secrets out of it.
