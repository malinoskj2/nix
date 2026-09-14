# CLAUDE.md

## Repository overview

This is a multi-host NixOS flake:

- `home`: primary desktop, with Hyprland, NVIDIA, and Home Manager.
- `katana`: ThinkPad, with the shared Home Manager configuration.
- `pi`: aarch64 server.
- `media`: media server with Docker and NVIDIA transcoding.

The flake uses flake-parts. `hosts/default.nix` is a flake-parts module that
builds every host with `nixpkgs.lib.nixosSystem` and holds the module shared by
all of them (overlays, unfree, Home Manager wiring). Host modules live under
`hosts/<name>/`; shared user configuration lives under
`users/jesse/`. Overlays live in `overlays/default.nix`: `pins` takes packages
from exact nixpkgs revisions, and `modifications` overrides existing packages,
using patches from `patches/<package>/`. The `apple-fonts` input's overlay adds
`pkgs.sf-pro`, `sf-compact`, `sf-mono` and `ny`.

Format changed Nix files with `nixfmt`. Prefer evaluating or building the
affected host before applying it, and do not run a `switch` unless explicitly
requested.

## Update gotchas

### Stable release inputs move together

`nixpkgs`, `home-manager`, and `catppuccin` are all pinned to matching release
branches in `flake.nix`. When changing the NixOS release, update all three to
the same release series. `nixpkgs-unstable` is intentionally separate and is
used for selected packages.

### Hyprland and its plugins are a coupled update

Do not treat the Hyprland inputs as ordinary flake-lock updates:

- `nixpkgs-hyprland` supplies Hyprland, `hyprlandPlugins`, and
  `xdg-desktop-portal-hyprland` from an exact nixpkgs revision.
- `hyprbars` comes from that revision's matching `hyprlandPlugins` set.
- The `modifications` overlay in `overlays/default.nix` overrides that same
  set's hyprfocus and applies all three `patches/hyprfocus/*.patch` files.
- That overlay and the desktop Home Manager module assert the exact supported
  Hyprland version.

When upgrading Hyprland, update the exact nixpkgs revision and version
assertions together. Rebase and review every hyprfocus patch against the new
Hyprland/plugin internals, confirm the revision's hyprbars has the required
features, then build the `home` host. A plain `nix flake update` will not advance
the input whose revision is embedded in its URL.

### Firefox and WaveFox must remain compatible

`nixpkgs-firefox` is pinned to an exact nixpkgs revision, and `wavefox` is
pinned to a release matching that Firefox major version. Update them together.
Afterward, verify `users/jesse/firefox.nix`: its Nova setting, imported WaveFox
CSS, cascade-layer ordering, and transparent chrome can all be sensitive to a
Firefox or WaveFox UI change.

### Apple fonts are pinned to a community flake revision

`apple-fonts` (`github:Lyndeno/apple-fonts.nix`) is pinned to an exact commit
in its URL, so `nix flake update` will not advance it. Its lock records the
hash of each `.dmg` from Apple's download URLs, and Apple replaces those files
in place. Once Apple ships a new version, a machine without a cached copy fails
to fetch with a hash mismatch. The fix is to bump the pinned commit to a newer
one (upstream updates the font hashes daily), then `nix flake lock`. Afterward,
check that `users/jesse/dolphin.nix` still finds `SF-Pro-Text-*.otf` in
`${pkgs.sf-pro}/share/fonts/opentype`.

### Other manual version pins

The `home` host defines a custom NVIDIA driver in `hosts/home/wayland.nix`.
Updating it requires changing the version and every driver hash as a unit.
This is independent of the normal flake input update.

Never bump `system.stateVersion` or `home.stateVersion` as part of a routine
package/channel update. Those values describe the installation's compatibility
baseline, not the current NixOS or Home Manager release.

### Evaluation is intentionally impure on some hosts

The configuration depends on files outside this repository:

- `/secret/secrets.nix` for the `media` host.
- `/home/jesse/env` for remaining shared Home Manager dotfile sources used by
  `home` and `katana`. The `home` Hyprland and Noctalia desktop is fully owned
  by `users/jesse/desktop-home` and must not gain a dependency on `env` again.

Do not copy secrets into the repository. Use `--impure` when evaluating or
building hosts that reference these absolute paths. The existing build scripts
encode the expected flags for `home`, `katana`, and `pi`.

Generated `hardware-configuration.nix` files should not be hand-edited during
an update. Also remember that newly added Nix source files must be tracked by
Git before flake evaluation can see them.
