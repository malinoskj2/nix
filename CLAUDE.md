# CLAUDE.md

## Repository overview

This flake builds four NixOS hosts and one nix-darwin host:

- `home`: primary desktop, with Hyprland, NVIDIA and Home Manager.
- `katana`: ThinkPad, with Hyprland and Home Manager.
- `pi`: aarch64 server with its own `pi` user and no Home Manager.
- `media`: media server with Docker and NVIDIA transcoding.
- `macbook`: Apple-silicon nix-darwin host with a conservative, user-scoped
  Home Manager profile.

### Flake

The flake uses flake-parts. `flake.nix` holds only inputs and imports the
single-concern modules in `flake/`:

- `nixpkgs.nix`: each platform's nixpkgs arguments (unfree and the overlay
  list), used by both the hosts and `perSystem` pkgs, and the exported
  overlays.
- `hosts.nix`: the host list, each built with its platform's nixpkgs arguments
  and the configuration revision.
- `packages.nix`: the local packages, taken from the overlaid pkgs.
- `checks.nix`: `host-<name>` for each host on its system, `package-<name>` for
  the local packages those hosts install directly, and `devshell`.
- `formatting.nix`: treefmt-nix.
- `devshell.nix`: treefmt, nh, nixd, nvd and the formatters.

### Hosts

Each host's entry is `hosts/<name>/configuration.nix`: an import list plus host
facts. Shared modules are imported explicitly by relative path from
`hosts/common/`:

- `global.nix`: what every NixOS host shares: flakes, git, vim, and a default
  timezone that pi overrides.
- `home-manager.nix`: Home Manager settings, for NixOS and nix-darwin.
- `users/jesse/default.nix`: jesse's account and SSH key, with the groups that
  exist on the host (docker, networkmanager).
- `users/jesse/interactive.nix`: for machines jesse sits at. It adds hardware
  and journal groups, imports Home Manager, and uses
  `users/jesse/profiles/<hostName>.nix` as his profile.
- `optional/`: one concern per file: `docker`, `fail2ban`, `fonts`, `hyprland`,
  `nh`, `openssh-hardening`, `pipewire`, `server-tools`, `sysctl-hardening`,
  `systemd-boot`, `workstation`.

Host-only policy, such as media's sudo and `mutableUsers`, stays in the host.

### Home Manager

The Home Manager hosts (`home`, `katana`, `macbook`) each have a profile at
`users/jesse/profiles/<name>.nix`. It declares that host's `home.stateVersion`
and imports `users/jesse/global/` (palette, session and the core program
modules) plus opt-in `users/jesse/features/`: `admin`, `cli`, `desktop`, `dev`,
`native` and `rust`. Only the `home` profile adds `features/rust/mold.nix`
(mold linker) and `features/rust/std-sources.nix` (`RUST_SRC_PATH`). Single
programs are flat modules at `users/jesse/<program>.nix` or
`users/jesse/<program>/`, imported by `global/`, a feature or a profile.
Identity comes from the OS account. `users/jesse/hyprland-desktop/` is the
Hyprland and Noctalia desktop, imported only by the `home` profile.

### Packages, overlays and patches

`pkgs/default.nix` is the single list of local packages
(`pkgs/<name>/package.nix`), exposed by the `additions` overlay as
`pkgs.<name>` and as `perSystem.packages`. Its `callPackage` supplies
claude-code, codex and noctalia from `pkgs.unstable`. Install local packages by
name. Linux-only packages set `meta.platforms`. `git-open-branch` installs the
`git-open` command.

`overlays/default.nix` holds `additions`, `unstable` (`pkgs.unstable`) and
`pins`. `pins` takes Firefox, Hyprland, the Hyprland plugins and the Hyprland
portal from exact nixpkgs revisions, and patches hyprfocus. The `apple-fonts`
input's overlay adds `pkgs.sf-pro`, `sf-compact`, `sf-mono` and `ny`.

Patches sit next to what applies them: a `pkgs/` package keeps its patch in its
own directory, and overlay patches live in `overlays/patches/<package>/`.

### Working here

Format and lint with `nix fmt` (treefmt: deadnix, statix and nixfmt for Nix,
shellcheck and shfmt for shell, ruff for Python, StyLua for Lua and Luau).
`nix flake check` also builds every host whose system matches, the local
packages those hosts install directly, and the devshell. Prefer evaluating or
building the affected host before applying it, and don't run a `switch` unless
explicitly asked. Hosts are applied with `nh os switch`. No host needs
`--impure`. Don't copy secrets into the repository.

## Updating inputs

@docs/updating.md

That file is the single source for update rules (coupled and commit-pinned
inputs, manual pins, Darwin overlays, stateVersion). Edit it rather than
restating rules here. On top of it, for agents:

- Build the affected host (`nix flake check`, or
  `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`) before
  proposing an apply. Never run `nh os switch`, `nixos-rebuild switch` or
  `darwin-rebuild switch` unless explicitly asked.
- `git add` new files before evaluating; flakes only see tracked files.
- Never bump `system.stateVersion` or `home.stateVersion`, and never hand-edit
  `hardware-configuration.nix`.
- Keep `nix.enable = false` on `macbook`; Determinate Nix owns its Nix
  installation (see `docs/bootstrap.md`).
- The `home` Hyprland and Noctalia desktop is fully declared under
  `users/jesse/hyprland-desktop/` and must not gain a dependency on the old
  `~/env` dotfiles checkout.
