# CLAUDE.md

## Repository overview

This is a multi-host NixOS flake:

- `home`: primary desktop, with Hyprland, NVIDIA, and Home Manager.
- `katana`: ThinkPad, with the shared Home Manager configuration.
- `pi`: aarch64 server.
- `media`: media server with Docker and NVIDIA transcoding.

Host modules live under `hosts/`; shared user configuration lives under
`users/jesse/`; custom packages and patches live under `derivations/` and are
exported through `overlays/derivations.nix`.

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
- `hyprland-plugins-src` supplies the custom `hyprbars` source from an exact
  upstream commit.
- `derivations/hyprfocus.nix` fetches another exact `hyprland-plugins` commit
  and applies all three `derivations/hyprfocus-*.patch` files.
- Both `derivations/hyprbars.nix` and `derivations/hyprfocus.nix` assert the
  exact supported Hyprland version.

When upgrading Hyprland, update the nixpkgs revision, both plugin source pins,
derivation versions and hashes, and version assertions together. Rebase and
review every hyprfocus patch against the new Hyprland/plugin internals, then
build the `home` host. A plain `nix flake update` will not advance the inputs
whose revisions are embedded in their URLs.

The comment in `derivations/hyprfocus.nix` mentions `hyprpm.toml`, but no such
file is currently tracked; the active pins are in `flake.nix` and the
derivation itself.

### Firefox and WaveFox must remain compatible

`nixpkgs-firefox` is pinned to an exact nixpkgs revision, and `wavefox` is
pinned to a release matching that Firefox major version. Update them together.
Afterward, verify `users/jesse/firefox.nix`: its Nova setting, imported WaveFox
CSS, cascade-layer ordering, and transparent chrome can all be sensitive to a
Firefox or WaveFox UI change.

### Other manual version pins

The `home` host defines a custom NVIDIA driver in `hosts/home/wayland.nix`.
Updating it requires changing the version and every driver hash as a unit.
This is independent of the normal flake input update.

Never bump `system.stateVersion` or `home.stateVersion` as part of a routine
package/channel update. Those values describe the installation's compatibility
baseline, not the current NixOS or Home Manager release.

### Evaluation is intentionally impure on some hosts

The configuration depends on files outside this repository:

- `/secret/secrets.nix` for the `home` and `media` hosts.
- `/secret/fonts` for the custom Apple font derivation.
- `/home/jesse/env` for Home Manager dotfile sources used by `home` and
  `katana`.

Do not copy secrets into the repository. Use `--impure` when evaluating or
building hosts that reference these absolute paths. The existing build scripts
encode the expected flags for `home`, `katana`, and `pi`.

Generated `hardware-configuration.nix` files should not be hand-edited during
an update. Also remember that newly added Nix source files must be tracked by
Git before flake evaluation can see them.

