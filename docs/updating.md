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

`nixpkgs-hyprland` pins the compositor and portal together. The j2bar input builds
its bundled focus/bar/glass/sheet/recede plugin against the exact host Hyprland
package; standalone effect packages and overlay patches are no longer installed. Their
retired sources remain in this repository pending packaged live desktop acceptance.
The desktop assertion in `users/jesse/hyprland-desktop/hyprland/default.nix` and
first-frame tearing patch assertion in `hosts/home/gaming.nix` require 0.56.2.

To upgrade, review/rebase `hosts/home/tearing-first-frame.patch` against the new
compositor, including cursor/DRM restrictions. Review the bundled native plugin
in the j2bar repository against the same pinned headers; a successful compile
alone does not establish compatibility. Check chooser opening/closing from
Firefox on both normal and rotated monitors, title-bar maximize/unload, live
panel glass and launcher recession without damage artifacts. Rebase
`pkgs/agent-sandbox/aquamarine-nested.patch` against the coupled backend, verify
`NESTED-1`, update version assertions, and build `home` before activation.

### j2bar

The pinned `j2bar` flake input supplies the Rust shell, bundled compositor plugin
and both game-engine architectures. Update that input only after its complete
Rust/native/private-GUI gates pass, then build this host. NixOS owns the sole
`j2bar.service`, admin policy, PAM service, runtime PATH and `/etc/xdg/j2bar/config.toml`.
Home Manager supplies the matching compositor library and key bindings; it does
not generate a second user config or duplicate shell service.

Exact glass, focus, title-bar, chooser and recession settings formerly in Lua
now live in `hosts/common/optional/j2bar.nix` under `settings.effects`. Lua retains
plugin loading, monitor topology, input and low-latency game/window policy.
Super+A opens the Assistant; other existing bindings stay the same.

A preexisting `~/.config/j2bar/config.toml` takes precedence over `/etc/xdg`.
Before eventual cutover, inspect and back it up or merge its intended overrides;
this repository does not delete personal state or config. Wallpaper assignments
remain at `$XDG_STATE_HOME/wallpaper/assignments.json`; the native player reuses
that schema. The workspace audio restoration journal remains at
`$XDG_STATE_HOME/game-workspace-audio/mute.json` and is retained. Stop the old
wallpaper and audio services before native workers start, while game playback
streams still exist so recorded mute state can be restored. No service or
running Steam process was changed while preparing these declarations.

The native limiter is opt-in per game: set Steam launch options to
`j2bar game-run -- %command%` (or `j2bar game-run -- GAME [ARGS...]` outside Steam).
The old global Steam engine injection is disabled; the independent
GameMode CPU policy/preload and first-frame tearing patch remain. Restart games
after eventual activation. Do not infer physical game latency from nested EGL
or software-renderer acceptance.

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
- **pyghidra-mcp.** [`pkgs/pyghidra-mcp/`](../pkgs/pyghidra-mcp) is the Ghidra
  MCP server for Claude Code and Codex on the host and in the agent sandbox,
  run over stdio by its `ghidra-mcp` launcher. It packages `ghidrecomp`
  inline. To move either, change `version` and refresh its hash, then rebase
  [`stdio-stdout.patch`](../pkgs/pyghidra-mcp/stdio-stdout.patch): ghidrecomp
  and Ghidra print to stdout, so in stdio mode the patch gives the MCP stream
  its own copy of stdout and points fd 1 at stderr. Check it by importing a
  binary, decompiling a function and running `gen_callgraph` over stdio, with
  nothing but JSON-RPC on stdout. LaurieWired's GhidraMCP needs the exact
  Ghidra version it was built for, which nixpkgs may not have.

## Background game FPS limiting

The j2bar input owns the native Vulkan/GLX/EGL engine and source/license notes.
Enable it per game with `j2bar game-run -- %command%`; the shell owns focus
tracking and workspace-5 audio restoration. The old standalone controller,
audio daemon and global Steam loader injection are absent. Preserve GameMode
and the compositor tearing patch when updating. Verify both engine architectures
inside Steam's actual pressure-vessel runtime, controller loss/focus recovery
and representative games before claiming latency or overhead results. Historical
standalone measurements remain history, not proof of the new launch route.

## Things an update never touches

- `system.stateVersion` and `home.stateVersion` record each machine's install
  baseline, not the current release. Don't bump them during an update.
- Generated `hardware-configuration.nix` files come from the machine. Regenerate
  them there, and don't hand-edit them.

## General

- Flakes only see files Git tracks, so `git add` new files before evaluating.
- Every host evaluates without `--impure`. Keep it that way.
- The repository is public, so keep secrets out of it.
