# CLAUDE.md

## Repository overview

This flake builds four NixOS hosts and one nix-darwin host:

- `home`: primary desktop, with Hyprland, NVIDIA, and Home Manager.
- `katana`: ThinkPad, with Hyprland and Home Manager.
- `pi`: aarch64 server with its own `pi` user and no Home Manager.
- `media`: media server with Docker and NVIDIA transcoding.
- `macbook`: Apple-silicon nix-darwin host with a conservative,
  user-scoped Home Manager profile.

### Flake

The flake uses flake-parts. `flake.nix` holds only inputs and imports the
single-concern modules in `flake/`: `nixpkgs.nix` defines each platform's
nixpkgs config and overlay list (used both by hosts and by `perSystem` pkgs)
and exports the overlays; `hosts.nix` lists the hosts and applies that nixpkgs
setup and the configuration revision; `packages.nix`, `checks.nix` (each host on its system, the local packages hosts
install, and the devshell), `formatting.nix` (treefmt-nix) and
`devshell.nix` cover the rest.

### Hosts

Each host's entry is `hosts/<name>/configuration.nix`: an import list plus
host facts. Shared modules are imported explicitly by relative path from
`hosts/common/`:

- `global.nix`: what every NixOS host shares (flakes, git, vim, and a default
  timezone that pi overrides).
- `home-manager.nix`: Home Manager settings, for NixOS and nix-darwin.
- `users/jesse/default.nix`: jesse's account and SSH key, with the groups that
  exist on the host (docker, networkmanager).
- `users/jesse/workstation.nix`: for machines jesse sits at. It adds hardware and
  journal groups, imports Home Manager, and uses
  `users/jesse/hosts/<hostName>.nix` as his profile.
- `optional/`: one concern per file (`docker`, `fail2ban`, `fonts`, `hyprland`,
  `nh`, `openssh-hardened`, `pipewire`, `server-tools`, `sysctl-hardening`,
  `systemd-boot`, `workstation`).

Host-only policy, such as media's sudo and `mutableUsers`, stays in the host.

### Home Manager

`users/jesse/hosts/<name>.nix` is each host's profile. It declares that host's
`home.stateVersion` and imports `users/jesse/global/` (palette, session and core
program modules) plus opt-in `users/jesse/features/`: `admin`, `cli`,
`datagrip`, `desktop`, `dev`, `native`, and `rust` (whose `session.nix` adds
rust-analyzer and mold variables). Identity comes from the OS account.
`users/jesse/desktop-home` is the home-only Hyprland and Noctalia desktop.

### Packages, overlays and patches

`pkgs/default.nix` is the single list of local packages
(`pkgs/<name>/package.nix`), exposed by the `additions` overlay as
`pkgs.<name>` and as `perSystem.packages`. Install them by name. Linux-only
packages set `meta.platforms`. `git-open-branch` installs the `git-open`
command.

`overlays/default.nix` holds `additions`, `unstable` (`pkgs.unstable`) and
`pins`: packages from exact nixpkgs revisions, including the patched hyprfocus
from the pinned Hyprland plugin set. The `apple-fonts` input's overlay adds
`pkgs.sf-pro`, `sf-compact`, `sf-mono` and `ny`.

Patches sit next to what applies them: a `pkgs/` package keeps its patch in its
own directory, and overlay patches live in `overlays/patches/<package>/`.

Darwin uses release-matched `nixpkgs-darwin` and `nix-darwin` inputs and only
the `additions` and `unstable` overlays. Do not add the Linux-specific `pins`
overlay to Darwin. Determinate Nix owns the Mac's Nix installation, so keep
`nix.enable = false`.

### Working here

Format and lint with `nix fmt` (treefmt: nixfmt, deadnix, statix, shellcheck).
`nix flake check` also builds every host whose system matches, the local packages those hosts install directly, and the devshell. Prefer
evaluating or building the affected host before applying it, and do not run a
`switch` unless explicitly requested. Hosts are applied with `nh os switch`.
No host needs `--impure`. Do not copy secrets into the repository.

## Updating inputs

@docs/updating.md

That file is the single source for update rules (coupled and commit-pinned
inputs, manual pins, stateVersion). Edit it rather than restating rules here.
On top of it, for agents:

- Build the affected host (`nix flake check`, or
  `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`)
  before proposing an apply. Never run `nh os switch`, `nixos-rebuild switch`
  or `darwin-rebuild switch` unless explicitly asked.
- `git add` new files before evaluating; flakes only see tracked files.
- Never bump `system.stateVersion` or `home.stateVersion`, and never hand-edit
  `hardware-configuration.nix`.
- The `home` Hyprland and Noctalia desktop is fully declared under
  `users/jesse/desktop-home` and must not gain a dependency on the old `~/env`
  dotfiles checkout.
