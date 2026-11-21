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

`home` limits Nix to one build with 16 cores. The sandbox's Blender also uses
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

`nixpkgs-hyprland` pins the compositor and portal together. The `tohru` input's
plugin (focus dips, title bars, chooser sheets and launcher recession) is built
against the exact host Hyprland package, and its own `hyprland-nixpkgs` input
follows `nixpkgs-hyprland`. The desktop assertion in
`users/jesse/hyprland-desktop/hyprland/default.nix`, the plugin package and the
first-frame tearing patch assertion in `hosts/home/gaming.nix` require 0.56.2.

To upgrade, review/rebase `hosts/home/tearing-first-frame.patch` against the new
compositor, including cursor/DRM restrictions. Review the plugin in the Tohru
repository against the same pinned headers; a successful compile alone does not
establish compatibility. Check chooser opening/closing from Firefox on both
normal and rotated monitors, title-bar maximize/unload and launcher recession
without damage artifacts. Rebase `pkgs/agent-sandbox/aquamarine-nested.patch`
against the coupled backend, verify `NESTED-1`, update version assertions, and
build `home` before activation.

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
  Rebase
  [`catppuccin.patch`](../pkgs/orca-ade/catppuccin.patch), which maps Orca's
  dark application tokens and every Monaco editor surface to Catppuccin Mocha.
  Upstream may add new dark-mode variables or Monaco call sites, so search for
  the `.dark` token block, the shared `.dark,
  .native-chat-appearance[data-native-chat-scheme='dark']` status and diff
  block, and `vs-dark` when rebasing it. Editors pick their theme in
  `useMonacoTheme`, and the Markdown TextMate tokens redefine each theme with
  Shiki's rules, so the patch adds Shiki's `catppuccin-mocha` rules there. Rebase
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
  [`local-default-base.patch`](../pkgs/orca-ade/local-default-base.patch),
  which starts a new worktree from the local default branch (`main`) instead
  of the detected `origin/main` when neither the caller nor `orca repo
  set-base-ref` chose a base and that local branch exists, in
  `resolveWorktreeCreateBase`, which every create path shares, and
  [`bundled-plugins.patch`](../pkgs/orca-ade/bundled-plugins.patch), which lets
  Orca's launch-plugin index carry a third-party plugin without marking it
  official, and [`approved-plugins.patch`](../pkgs/orca-ade/approved-plugins.patch),
  which treats the plugins in `approvedPlugins` as consented. Rebase
  [`agent-resume-wrapper.patch`](../pkgs/orca-ade/agent-resume-wrapper.patch),
  which runs the Claude, Codex, Muse and Antigravity resumes Orca starts when
  it reopens through `agentResumeWrapper` as `<wrapper> <agent> <args>`, for
  local workspaces only. `home` sets it to
  `agent-sandbox-resume` (`orca.agentResumeWrapper` in
  [`agent-sandbox.nix`](../users/jesse/agent-sandbox.nix)), which resumes in a
  sandbox the sessions a sandbox started; other hosts leave it unset. Upstream
  may add another automatic resume path besides the pane cold restore. The
  build adds
  jondmarien/orca-discord-presence to that index from
  one pinned commit; to move it, change `rev` and refresh its hash. The
  `postPatch` merges `discordPresenceSettings` into the plugin's compiled
  defaults, lets its URL and token settings fall back to them (upstream reads
  those only from saved settings), turns off its panel rewrite and changes its
  generic details line to "Working in Orca ADE", all with
  `--replace-fail` against `dist/main.js`. It also adds
  Etherll/orca-usage-insights pinned to one release commit, a full-access plugin that
  reads local Claude, Codex and OpenCode transcripts. Orca never updates a
  bundled plugin from its catalog. To move it, set `rev` to the new release tag's commit,
  refresh its hash and review the new release's source before bundling it: check
  what it fetches, spawns and writes. `usageInsightsSettings` becomes the
  manifest's setting defaults, and an unknown key fails the build. `home` adds
  the sandbox's Codex home there, since sandboxed Claude already shares
  `~/.claude/projects`. The `postPatch` also edits upstream source in place: it drops
  the AppImage's glibc floor check and its downloaded Node runtime, skips the
  Docker build of the Wayland clipboard helper, which `buildPhase` compiles
  instead, builds the provider exec helper and the journal file lock with the
  host compiler instead of Docker, turns on keeping the computer awake while agents run, and makes
  directories it uploads over SSH writable after they're extracted on the
  remote. Each uses `--replace-fail`, so a moved line fails the build; find
  where the new release does the same thing. Then, in Orca:
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
    [`features/desktop.nix`](../users/jesse/features/desktop.nix) links from
    the release's `skills/`, so a renamed or added skill leaves it undone.
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
[game-latency.md](game-latency.md#background-frame-limit). Preserve GameMode and
the compositor tearing patch when updating.

## Things an update never touches

- `system.stateVersion` and `home.stateVersion` record each machine's install
  baseline, not the current release. Don't bump them during an update.
- Generated `hardware-configuration.nix` files come from the machine. Regenerate
  them there, and don't hand-edit them.

## General

- Flakes only see files Git tracks, so `git add` new files before evaluating.
- Every host evaluates without `--impure`. Keep it that way.
- The repository is public, so keep secrets out of it.
