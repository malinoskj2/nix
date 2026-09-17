# Updating

Most inputs follow a branch and move with `nix flake update`. A few are pinned
to an exact revision in their URL, or have to move together with something
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

`nixpkgs`, `home-manager`, `catppuccin`, `nixpkgs-darwin` and `nix-darwin` all
follow branches for the same NixOS release. To change release, move all five to
the new release's branches in one commit. The macOS switch command in
[`docs/bootstrap.md`](bootstrap.md) runs `darwin-rebuild` from the locked
`nix-darwin`, so it follows along.

`nixpkgs-unstable` doesn't follow the release. It supplies `pkgs.unstable` for
the few packages that need something newer.

### Hyprland

`nixpkgs-hyprland` is an exact nixpkgs commit. Hyprland, `hyprlandPlugins` and
`xdg-desktop-portal-hyprland` all come from it, so the compositor and its
plugins always share one ABI. hyprbars comes from that plugin set as-is.
hyprfocus comes from it too, patched by the `pins` overlay in
[`overlays/default.nix`](../overlays/default.nix). Two assertions check the
Hyprland version: `supportedHyprlandVersions` in that overlay and
`supportedHyprland` in
[`users/jesse/hyprland-desktop/hyprland/default.nix`](../users/jesse/hyprland-desktop/hyprland/default.nix).

To upgrade:

1. Point `nixpkgs-hyprland` at a nixpkgs commit with the new Hyprland.
2. Rebase each patch in
   [`overlays/patches/hyprfocus/`](../overlays/patches/hyprfocus). They hook
   Hyprland internals, so a clean apply isn't enough. Read them against the new
   source.
3. Confirm that commit's hyprbars still supports what
   [`hyprland.lua`](../users/jesse/hyprland-desktop/hyprland/hyprland.lua)
   uses: `bar_part_of_window`, `bar_precedence_over_border`, `bar_text_align`,
   `on_double_click`, and the `hyprbars:no_bar` window rule.
4. Update both version assertions.
5. Build `home`.

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
  [`hosts/home/nvidia.nix`](../hosts/home/nvidia.nix) builds a driver newer
  than the release's default. The version and every `sha256` change together.
  Copy them from the `production` entry of
  `pkgs/os-specific/linux/nvidia-x11/default.nix` in nixos-unstable.
- **htop.** [`pkgs/htop-vim-navigation/`](../pkgs/htop-vim-navigation) asserts
  the htop versions its patch was checked against. If a nixpkgs update trips
  it, re-check the patch next to it and add the new version.

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
