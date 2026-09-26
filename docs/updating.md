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

`nixpkgs`, `home-manager`, `catppuccin` and `nixpkgs-darwin` all follow
branches for the same NixOS release. To change release, move all four to the new
release's branches in one commit.

`nixpkgs-unstable` doesn't follow the release. It supplies `pkgs.unstable` for
the few packages that need something newer.

### Hyprland

`nixpkgs-hyprland` is an exact nixpkgs commit. Hyprland, `hyprlandPlugins` and
`xdg-desktop-portal-hyprland` all come from it, so the compositor and its
plugins always share one ABI. hyprbars comes from that plugin set as-is.
hyprfocus comes from it too, patched by the `pins` overlay in
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
   [`overlays/patches/hyprfocus/`](../overlays/patches/hyprfocus). They hook
   Hyprland internals, so a clean apply isn't enough. Read them against the new
   source.
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
   parents, window fadeouts and layout moves, and hooks
   `CWindowFadeout::create`, so a clean build isn't enough. Open a file chooser
   from Firefox and check that Firefox shrinks into the chooser and fades out
   as it opens, and grows back out of it as it closes, without Firefox
   re-laying out its page.
5. Rebase
   [`aquamarine-nested.patch`](../pkgs/agent-sandbox/aquamarine-nested.patch)
   onto that commit's Aquamarine, then start a sandbox and check that
   `hyprctl monitors` inside it lists `NESTED-1`.
6. Confirm that commit's hyprbars still supports what
   [`hyprland.lua`](../users/jesse/hyprland-desktop/hyprland/hyprland.lua)
   uses: `bar_part_of_window`, `bar_precedence_over_border`, `bar_title_enabled`,
   `on_double_click`, and the `hyprbars:no_bar` window rule.
7. Update all four version assertions.
8. Build `home`.

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
- **htop.** [`pkgs/htop-vim-navigation/`](../pkgs/htop-vim-navigation) asserts
  the htop versions its patch was checked against. If a nixpkgs update trips
  it, re-check the patch next to it and add the new version.
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
  release tag from source against `pkgs.unstable`'s Electron 43 and pnpm 11.
  To move it, change `version`, then refresh the source hash and both pnpm
  dependency hashes (the root and `mobile/` lockfiles). Rebase
  [`claude-hooks.patch`](../pkgs/orca-ade/claude-hooks.patch): it keeps Orca out
  of the read-only `~/.claude/settings.json` by writing its hooks to
  `~/.orca/agent-hooks/claude-settings.json` and passing that file with
  `--settings`. Upstream Claude launches move often, so check every one still
  gets the flag, not just the build. Then, in Orca:
  - check that a `claude` typed into an Orca terminal and one Orca launches
    both show working and done in the sidebar, with the running tool;
  - open a Claude chat tab (Settings → Experimental) and check that its
    `claude` process has `--settings`;
  - run `orca-ide agent hooks status --json` and check that Claude reports
    `installed`;
  - check that `~/.claude/settings.json` is unchanged and that a plain
    `claude` outside Orca has no Orca hooks.

## Darwin

The Mac's nixpkgs gets only the `additions` and `unstable` overlays. The
Linux-only `pins` overlay and the `apple-fonts` overlay never reach Darwin, so
don't add either to the `darwin` arguments in
[`flake/nixpkgs.nix`](../flake/nixpkgs.nix). A Hyprland, Firefox or Apple fonts
bump therefore never changes the Mac.

## Things an update never touches

- `system.stateVersion` and `home.stateVersion` record each machine's install
  baseline, not the current release. Don't bump them during an update.
- Generated `hardware-configuration.nix` files come from the machine. Regenerate
  them there, and don't hand-edit them.

## General

- Flakes only see files Git tracks, so `git add` new files before evaluating.
- Every host evaluates without `--impure`. Keep it that way.
- The repository is public, so keep secrets out of it.
