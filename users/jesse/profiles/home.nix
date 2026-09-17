{
  imports = [
    ../global

    ../features/admin.nix
    ../features/cli.nix
    ../features/desktop.nix
    ../features/dev.nix
    ../features/native.nix
    ../features/rust
    ../features/rust/mold.nix
    ../features/rust/std-sources.nix

    ../datagrip
    ../git.nix
    ../hyprland-desktop
  ];

  home.stateVersion = "25.11";
}
