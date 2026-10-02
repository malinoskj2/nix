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

## Inputs that move as a unit

### The release

`nixpkgs`, `home-manager` and `catppuccin` all follow
branches for the same NixOS release. To change release, move all three to the new
release's branches in one commit. A new release can also break the hy3dgen and
Eisvogel pins in [Pins outside `flake.lock`](#pins-outside-flakelock), which
depend on its Python and TeX Live.

`nixpkgs-unstable` doesn't follow the release. It supplies `pkgs.unstable` for
the few packages that need something newer.

### Hyprland

`nixpkgs-hyprland` is an exact nixpkgs commit. Hyprland, `hyprlandPlugins` and
`xdg-desktop-portal-hyprland` all come from it, so the compositor and its
plugins always share one ABI. hyprbars and hyprfocus come from that plugin
set, patched by the `pins` overlay in
[`overlays/default.nix`](../overlays/default.nix). hyprglass isn't in that
set: [`pkgs/hyprglass/`](../pkgs/hyprglass) builds one hyprglass release
against the pinned Hyprland and patches its layer glass.
[`pkgs/hyprsheet/`](../pkgs/hyprsheet) is a local plugin built against the
pinned Hyprland that draws a file chooser's parent scaled into the chooser.
Four assertions check the Hyprland version: `supportedHyprlandVersions` in that
overlay, in `pkgs/hyprglass/package.nix` and in `pkgs/hyprsheet/package.nix`,
and `supportedHyprland` in
[`users/jesse/hyprland-desktop/hyprland/default.nix`](../users/jesse/hyprland-desktop/hyprland/default.nix).

To upgrade:

1. Point `nixpkgs-hyprland` at a nixpkgs commit with the new Hyprland.
2. Rebase each patch in
   [`hosts/home/tearing-first-frame.patch`](../hosts/home/tearing-first-frame.patch),
   [`overlays/patches/hyprbars/`](../overlays/patches/hyprbars) and
   [`overlays/patches/hyprfocus/`](../overlays/patches/hyprfocus). They hook
   Hyprland internals, so a clean apply isn't enough. Read them against the new
   source. The Hyprland tearing patch checks first-frame eligibility without
   requiring that frame to already be marked torn; remove it if upstream fixes
   that check, and verify fullscreen tearing and direct scanout with `hyprctl monitors`.
   Check the visible-cursor path separately: the
   [cursor/tearing investigation](../users/jesse/claude/skills/game-latency/references/cursor-tearing.md)
   records the Linux/NVIDIA/Aquamarine restrictions behind Hyprland's software
   cursor policy. Async flip capability alone does not justify removing its
   cursor guards. Re-check the matching kernel, driver and backend on upgrades.
   One hyprbars patch drops the plugin's event listeners when it
   unloads, so check that upstream hasn't added a listener it misses. The
   other adds the bar through the renderer's current pass, so a window
   transformer scales and fades it with its window.
3. Move hyprglass to the release that its `hyprpm.toml` pairs with the new
   Hyprland, and rebase
   [`layer-shape.patch`](../pkgs/hyprglass/layer-shape.patch) onto it. hyprglass
   hooks Hyprland's private `renderLayer`, so open a floating panel (the clock's
   calendar) and an attached one (the control center) and check their glass,
   not just the build. The floating panel's top rim should gleam once as it
   opens, and its edges shouldn't flicker dark while it scales in; the
   attached one shouldn't gleam. Then send two notifications: each banner
   should have its own rounded glass, even while one slides in or out.
4. Read [`pkgs/hyprsheet/main.cpp`](../pkgs/hyprsheet/main.cpp) against the
   new source. It uses Hyprland's private window transformers, xdg-foreign
   parents, window fadeouts and layout moves, hooks `CWindowFadeout::create`,
   hides the parent through its move-from-workspace alpha and its no-focus
   rule, and relies on
   Hyprland passing a transformed window's blur matte through its
   transformers, so a clean build isn't enough. Check that Hyprland still
   skips drawing a window at alpha 0 and sends it no frame callbacks, and still
   sets that alpha only when a window maps, unmaps or changes workspace. Open a
   file chooser from Firefox and check that Firefox shrinks into the chooser
   and fades out as it opens, and grows back out of it as it closes, without
   Firefox re-laying out its page. Its translucent toolbar should keep its blur
   as it fades, not lose it on the first frame, the wallpaper shouldn't flash
   through either way, and the snowflake widget in the top-left corner should
   stay whole. Once the chooser has come to rest its text and glass shouldn't
   change or shimmer. Focus another window, then focus the chooser again by
   keyboard: it should dip like any window, with hyprfocus's animations,
   without its buttons changing size. Moving the pointer onto it shouldn't
   dip it. Do the same from Alacritty: its title bar should shrink
   with it, not stay behind until the chooser has opened.
5. Rebase
   [`aquamarine-nested.patch`](../pkgs/agent-sandbox/aquamarine-nested.patch)
   onto that commit's Aquamarine, then start a sandbox and check that
   `hyprctl monitors` inside it lists `NESTED-1`.
6. Confirm that commit's hyprbars still supports what
   [`hyprland.lua`](../users/jesse/hyprland-desktop/hyprland/hyprland.lua)
   uses: `bar_part_of_window`, `bar_precedence_over_border`, `bar_title_enabled`,
   `on_double_click`, and the `hyprbars:no_bar` window rule.
7. Update all version assertions, including the desktop tearing patch in `hosts/home/gaming.nix`.
8. Build `home`.

### j2bar

`j2bar` is the shell of the `home` desktop and is managed manually while it is
in development. This flake does not fetch, build or install its binary. Desktop
bindings and wallpaper tools use `~/projects/j2bar/target/release/j2bar`, selected
by `J2BAR_BIN`. Build it in the bar's own repository; `nix flake update` does not
update it. Wallpaper tools also accept a `J2BAR_BIN` override, falling back to
`j2bar` on `PATH` when it is unset.

After a Hyprland upgrade, run j2bar's golden test and check its surfaces against
[`look.lua`](../users/jesse/hyprland-desktop/hyprland/look.lua), whose layer
rules and hyprglass layers name j2bar's namespaces.

Bar settings live in the regular `~/.config/j2bar/config.toml` file and are edited directly.
A Nix switch does not generate or place that file. Hyprland's bindings and layer
rules, the PAM lock service, fonts and wallpaper tools remain declared in this flake.

### Firefox

`nixpkgs-firefox` is an exact nixpkgs commit, and `wavefox` is the WaveFox
release for that Firefox major version. Move them together. Then open Firefox
and check what [`users/jesse/firefox.nix`](../users/jesse/firefox.nix) depends
on: the Nova setting, the imported WaveFox CSS, the cascade-layer order and the
transparent chrome. A Firefox or WaveFox UI change can break any of them
without a build error.

## Inputs pinned to a commit

### `apple-fonts`

[Lyndeno/apple-fonts.nix](https://github.com/Lyndeno/apple-fonts.nix) records
hashes of Apple's `.dmg` downloads, but Apple replaces those files in place. A
machine that doesn't already have a file then fails with a hash mismatch, and
so does CI. To fix it, move the pinned commit to a recent one (upstream
refreshes the hashes daily), run `nix flake lock`, and check that the Dolphin
font build in [`users/jesse/dolphin/`](../users/jesse/dolphin) still finds
`SF-Pro-Text-*.otf` under `${pkgs.sf-pro}/share/fonts/opentype`.

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
  [`overlays/default.nix`](../overlays/default.nix) builds claude-code from
  [`overlays/claude-code/manifest.zst.json`](../overlays/claude-code/manifest.zst.json)
  instead of the version in `nixpkgs-unstable`. To move it, replace that file
  with `https://downloads.claude.ai/claude-code-releases/<version>/manifest.zst.json`.
  Drop the override once `nixpkgs-unstable` catches up.
- **Codex.** The `unstable` overlay builds Codex from a newer `rust-v<version>`
  tag than `nixpkgs-unstable` has, because OpenAI doesn't offer its newest
  models to older clients. It carries nixpkgs' own patch and `postPatch` for
  that version, with the patch in
  [`overlays/patches/codex/`](../overlays/patches/codex). To move it, change
  `version`, then refresh the source hash and the cargo vendor hash, and copy
  any new patch or `postPatch` line from nixpkgs' `pkgs/by-name/co/codex/`.
  Drop the override once `nixpkgs-unstable` catches up.
- **htop.** [`pkgs/htop-vim-navigation/`](../pkgs/htop-vim-navigation) asserts
  the htop versions its patch was checked against. If a nixpkgs update trips
  it, re-check the patch next to it and add the new version.
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
- **Noctalia.** The `unstable` overlay in
  [`overlays/default.nix`](../overlays/default.nix) patches Noctalia so floating
  panels skip its clip reveal and Hyprland scales them in instead, so a bar
  widget's panel centers under the widget, so a plugin panel can set its own
  padding and resize to fit its content, so plugin sliders can be styled, so
  notification toasts are laid out like macOS 27's banners and slide in and
  out across the screen edge, so a desktop widget's panel opens under the
  widget and plugin rows take a right click, and so a bar widget can turn off
  its hover tooltip. It asserts the version the patches
  were checked against. When `nixpkgs-unstable` moves Noctalia, re-check
  [`overlays/patches/noctalia/`](../overlays/patches/noctalia) against the new
  source, then:
  - click the clock (the calendar should open centered under it);
  - hover the volume icon (no tooltip should appear), then click it (the sound
    menu should open centered under it, with a thin peach slider);
  - hover the network icon (no tooltip should appear), then click it (the
    network menu should scale in at its final size, then grow when Other
    Networks expands);
  - click the snowflake button (the system menu should open below the bar with
    its left edge under the button's), then right-click it (the control center
    should open);
  - open the control center;
  - send a few notifications with `notify-send` (each banner should slide in
    from the right with its own rounded glass, and slide back out when it
    expires).
- **Claude Desktop.** [`pkgs/claude-desktop/`](../pkgs/claude-desktop) fetches
  one `.deb` from Anthropic's APT repository. To move it, copy the newest
  `Version` and `SHA256` from
  `https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages`.
  The build patches hardcoded paths in `app.asar` and fails if one is gone;
  find where the new release looks instead.
- **Orca.** [`pkgs/orca-ade/`](../pkgs/orca-ade) builds one stablyai/orca
  release tag from source against `pkgs.unstable`'s Electron 43, Node 24 and
  pnpm 11. To move it, change `version`, then refresh the source hash and both
  pnpm dependency hashes (the root and `mobile/` lockfiles). Keep `electron_43`
  and `nodejs_24` on the majors the release's `package.json` names in
  `electron` and `engines.node`. Its `packageManager` is pnpm 12, which
  `nixpkgs-unstable` doesn't have yet, so `pnpm_11` builds it until `pnpm_12`
  lands. Rebase
  [`catppuccin.patch`](../pkgs/orca-ade/catppuccin.patch), which maps Orca's
  dark application tokens and every Monaco editor surface to Catppuccin Mocha.
  Upstream may add new dark-mode variables or Monaco call sites, so search for
  both the `.dark` token block and `vs-dark` when rebasing it. Rebase
  [`glass-titlebar.patch`](../pkgs/orca-ade/glass-titlebar.patch) when Orca
  changes its Electron window options or top-bar layout, then confirm only the
  36px titlebar band shows compositor blur. Rebase
  [`claude-hooks.patch`](../pkgs/orca-ade/claude-hooks.patch): it keeps Orca out
  of the read-only `~/.claude/settings.json` by writing its hooks to
  `~/.orca/agent-hooks/claude-settings.json` and passing that file with
  `--settings`. Over SSH it writes the same file on the remote, which the agent
  sandbox's `claude` wrapper loads. Upstream Claude launches move often, so
  check every one still gets the flag, not just the build. Also rebase
  [`open-video-externally.patch`](../pkgs/orca-ade/open-video-externally.patch),
  which opens a clicked video path with the system default (mpv) instead of
  Orca's editor. The `postPatch` also edits upstream source in place: it drops
  the AppImage's glibc floor check, turns on keeping the computer awake while
  agents run, and makes the SSH relay writable after it's extracted on the
  remote. Each uses `--replace-fail`, so a moved line fails the build; find
  where the new release does the same thing. Then, in Orca:
  - check that a `claude` typed into an Orca terminal and one Orca launches
    both show working and done in the sidebar, with the running tool, locally
    and in a sandbox workspace over SSH;
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
  - check that Getting started shows Enable Orca CLI as done. It only looks
    for the `orca-cli`, `computer-use` and `orchestration` skills, which
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
- **zcode.** [`pkgs/zcode/`](../pkgs/zcode) builds the terminal harness from one
  zai-org/ZCode commit (Z.ai publishes no prebuilt CLI; the desktop binaries on
  GitHub and their CDN are Electron only). It stages the agent bundle, the
  official TUI runtime and `playwright-core` with upstream's own staging
  scripts into the layout their `build:zcode` distribution uses, minus the
  `--web` server and client. To move it, change `rev`, refresh the source hash
  and the pnpm dependency hash, and re-check the `pnpmFieldPatch`: pnpm ignores
  the `pnpm.overrides` and `patchedDependencies` fields in the root
  `package.json` but still enforces them against the lockfile, so the patch
  appends them to `pnpm-workspace.yaml`; if upstream moves or drops them, drop
  the patch. Then run `zcode --version` and `zcode doctor`.

## Background game FPS limiting

[`game-background-engine`](../pkgs/game-background-engine/) is a local standalone
Vulkan/GLX/EGL limiter, with narrow MIT-licensed MangoHud adaptations documented
in its [source notes](../pkgs/game-background-engine/SOURCES.md). It does not
link or load MangoHud. [`game-background-limit`](../pkgs/game-background-limit/)
provides the physical Hyprland event controller and manual launcher; the home
Steam profile injects both engine architectures automatically.

After graphics loader/header, Steam runtime, libc or Hyprland updates, build the
engine/controller checks and the home host. Verify both pointer widths through
Steam's actual pressure-vessel runtime, including loader chains, proc-address
presentation routes, focus loss/regain, and uncapping after compositor or
controller failure. Keep the focused atomic bypass free of clocks, config reads,
pacing locks and sleeps, and keep background waits interruptible. Review helper
names if Steam changes its launch chain. Preserve the included upstream MIT
notice. Runtime compatibility and focused overhead still need representative
game checks; an isolated software renderer does not establish AION performance.
See [game latency](game-latency.md#background-frame-limit) for activation and
per-game opt-out instructions.

## Things an update never touches

- `system.stateVersion` and `home.stateVersion` record each machine's install
  baseline, not the current release. Don't bump them during an update.
- Generated `hardware-configuration.nix` files come from the machine. Regenerate
  them there, and don't hand-edit them.

## General

- Flakes only see files Git tracks, so `git add` new files before evaluating.
- Every host evaluates without `--impure`. Keep it that way.
- The repository is public, so keep secrets out of it.
