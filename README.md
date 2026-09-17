# nix

[![Check](https://github.com/malinoskj2/nix/actions/workflows/check.yml/badge.svg)](https://github.com/malinoskj2/nix/actions/workflows/check.yml)

The NixOS and nix-darwin configuration for my machines, as one flake built
with [flake-parts](https://flake-parts.hercules-ci.com). The workstations
(`home`, `katana`, `macbook`) also get their user environment through
[Home Manager](https://github.com/nix-community/home-manager). The servers
(`media`, `pi`) are system-only.

It isn't meant to be imported as-is. Borrow whatever's useful.

## Hosts

| Host | Hardware | Platform | Role |
| --- | --- | --- | --- |
| [`home`](hosts/home) | Ryzen 9 9950X3D, NVIDIA | `x86_64-linux` | Main desktop. Hyprland and Noctalia, Limine with Secure Boot, dual-boots Windows. |
| [`katana`](hosts/katana) | ThinkPad X230 | `x86_64-linux` | Laptop. Hyprland session and the shared Home Manager profile. |
| [`media`](hosts/media) | Intel, RTX 3060 Ti | `x86_64-linux` | Headless media server. Docker stack with NVIDIA transcoding, reachable from the internet. |
| [`pi`](hosts/pi) | Raspberry Pi 4 | `aarch64-linux` | LAN box. Samba share and Docker. |
| [`macbook`](hosts/macbook) | Apple silicon MacBook | `aarch64-darwin` | nix-darwin with a user-scoped Home Manager profile. Determinate Nix owns the Nix install. |

## Layout

| Path | Contents |
| --- | --- |
| [`flake.nix`](flake.nix) | Inputs, with a comment on each pinned one |
| [`flake/`](flake) | flake-parts modules: host list, how nixpkgs is instantiated (unfree, overlay order), packages, checks, formatter, devshell |
| [`hosts/<name>/`](hosts) | One directory per machine. `configuration.nix` is the entry point, and its imports list what the machine runs. |
| [`hosts/common/`](hosts/common) | Shared modules: the baseline for every NixOS host, Home Manager settings, opt-in modules under `optional/`, and accounts under `users/` |
| [`users/jesse/`](users/jesse) | Home Manager: `global/` shared by every profile, opt-in `features/`, one profile per machine in `hosts/`, and a module per program |
| [`pkgs/`](pkgs) | Local packages, one directory each. Exported as `packages` and the `additions` overlay. |
| [`overlays/`](overlays) | `pkgs.unstable`, packages taken from exact nixpkgs commits, and patched packages with their patches |
| [`docs/`](docs) | [Bootstrapping a host](docs/bootstrap.md), [updating inputs](docs/updating.md) |

Each host is `nixosSystem` or `darwinSystem` applied to its own
`configuration.nix`. There's no custom builder and no options framework. A
host imports what it needs by path, Home Manager included, so to see what a
machine runs, follow the imports from its `configuration.nix`.

## Usage

The devshell provides treefmt, nh, nixd and nvd. With direnv, `direnv allow`
loads it automatically.

```sh
nix develop
nix fmt               # deadnix, statix, nixfmt, shellcheck
nix flake check       # formatting, plus every host for this machine's system
nix build .#nixosConfigurations.home.config.system.build.toplevel
nh os switch --ask    # shows the package diff and asks before activating
```

`nh` is configured with the checkout at `/home/jesse/nix` and picks the
configuration matching the hostname. `pi` has no `jesse` account, so pass it
the path there. To set up a fresh machine or the Mac, see
[docs/bootstrap.md](docs/bootstrap.md).

The scripts in `pkgs/` build on their own too. `nix flake show` lists them.

```sh
nix run github:malinoskj2/nix#pubip
```

## Notable pieces

### Infrastructure

- **Every host is built in CI.** [`flake/checks.nix`](flake/checks.nix) turns
  each host into a check for its own system, so `nix flake check` on each
  native runner builds that system's hosts instead of only evaluating them.
- **Formatting and lint** go through
  [treefmt-nix](https://github.com/numtide/treefmt-nix) and are part of the
  checks. deadnix and statix run before nixfmt so their fixes come out
  formatted.
- **Hardening for the internet-facing host.** `media` imports key-only SSH on
  a non-default port, escalating fail2ban bans, and kernel sysctl hardening
  from [`hosts/common/optional`](hosts/common/optional). Its user accounts are
  immutable.
- **Patched packages carry their own guard.** Every local patch asserts the
  upstream version it was written for, so a nixpkgs bump fails at evaluation
  instead of misbehaving at runtime. The `additions` overlay also refuses local
  packages that would shadow a nixpkgs name.
- **One palette.** [`palette.nix`](users/jesse/palette.nix) is a read-only
  option with the Catppuccin colors and glass opacities. Firefox, Zed,
  Dolphin, fastfetch and the desktop all read from it.

### Desktop

- **Patched hyprfocus.** Three [patches](overlays/patches/hyprfocus) add a
  window-class filter, a way to combine animations (`flash,shrink`), and a
  shrink that scales at render time instead of resizing the client.
- **Hyprland in Lua.** The [compositor config](users/jesse/desktop-home/hyprland)
  uses Hyprland's Lua config. Nix passes in plugin paths, the palette and
  monitor names as Lua locals, so the config never hardcodes a store path.
- **Noctalia plugins.** [`control-button`](users/jesse/desktop-home/noctalia/plugins/control-button)
  is a floating button whose hover animation is rendered at build time from an
  SVG. [`hypr-workspaces`](users/jesse/desktop-home/noctalia/plugins/hypr-workspaces)
  draws per-workspace colored pills and redraws on Hyprland socket events
  instead of polling.
- **htop with h/j/k/l.** [`htop-vim-navigation`](pkgs/htop-vim-navigation)
  maps vim keys to arrow-key movement whenever no text field has focus.
- **Scheduler tuning on `home`.** [`scheduler.nix`](hosts/home/scheduler.nix)
  runs sched_ext `scx_bpfland` on the LTS kernel, tuned for the 9950X3D's two
  CCDs.

## Updating

`nix flake update` moves only the inputs that follow a branch. Hyprland,
Firefox and WaveFox, the Apple fonts and nixos-hardware are pinned to exact
commits or releases, and some of them have to move together.
[docs/updating.md](docs/updating.md) covers the procedure for each one.
Never bump `stateVersion` during an update.

## CI

- [`check.yml`](.github/workflows/check.yml) runs `nix flake check` on
  native x86_64-linux, aarch64-linux and aarch64-darwin runners, for pushes
  to `main` and for pull requests. Store paths that cache.nixos.org doesn't have go into
  the GitHub Actions cache through Magic Nix Cache. That cache is capped at
  about 10 GB and evicts, so the NVIDIA and Pi kernel builds sometimes run
  again. To keep them permanently, set the repository variable `CACHIX_NAME`
  and the secret `CACHIX_AUTH_TOKEN`.
- [`update.yml`](.github/workflows/update.yml) runs `nix flake update` every
  week and builds every host against the new lock. It opens a pull request
  only if all builds pass. By default `GITHUB_TOKEN` opens the pull request.
  That needs *Settings, Actions, General, Allow GitHub Actions to create and
  approve pull requests*, and GitHub runs no checks on such a pull request, so
  the body links the run that built it instead. To get normal checks, install
  a GitHub App with contents and pull-request write access, and set the
  `UPDATE_APP_CLIENT_ID` variable and `UPDATE_APP_PRIVATE_KEY` secret.
- [Dependabot](.github/dependabot.yml) keeps the SHA-pinned actions current.
