# ❄️ nix

[![Check](https://github.com/malinoskj2/nix/actions/workflows/check.yml/badge.svg)](https://github.com/malinoskj2/nix/actions/workflows/check.yml)
[![Update](https://github.com/malinoskj2/nix/actions/workflows/update.yml/badge.svg)](https://github.com/malinoskj2/nix/actions/workflows/update.yml)
[![NixOS 26.05](https://img.shields.io/badge/NixOS-26.05-5277C3?logo=nixos&logoColor=white)](https://nixos.org)
[![Hyprland](https://img.shields.io/badge/Hyprland-Lua-58E1FF?logo=hyprland&logoColor=white)](https://hyprland.org)
[![Catppuccin](https://img.shields.io/badge/theme-Catppuccin-F5C2E7)](https://catppuccin.com)
[![License: BSD-2-Clause](https://img.shields.io/badge/license-BSD--2--Clause-blue)](LICENSE)

NixOS and Home Manager configuration for my machines, as one
[flake-parts](https://flake-parts.hercules-ci.com) flake. Not meant to be
imported as-is. Borrow whatever's useful.

## ✨ Highlights

- 🪟 **Hyprland in Lua** with a [patched hyprfocus](overlays/patches/hyprfocus) and
  custom [Noctalia plugins](users/jesse/hyprland-desktop/noctalia/plugins)
- 🎨 **One Catppuccin palette** in [`palette.nix`](users/jesse/global/palette.nix),
  shared by every themed app
- 🤖 **Every host built in CI** on native x86_64-linux, aarch64-linux and
  aarch64-darwin runners, with weekly auto-updates
- ⚡ **sched_ext tuning** for the 9950X3D in [`scheduler.nix`](hosts/home/scheduler.nix)

## 🚀 Usage

```sh
nix develop
nix fmt
nix flake check
nh os switch --ask
```

Try a package directly:

```sh
nix run github:malinoskj2/nix#pubip
```

🖥️ New machine: [`docs/bootstrap.md`](docs/bootstrap.md). 🔄 Updating pinned inputs:
[`docs/updating.md`](docs/updating.md).
