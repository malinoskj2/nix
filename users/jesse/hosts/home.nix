{
  imports = [
    ../global
    ../features/admin.nix
    ../features/cli.nix
    ../features/datagrip
    ../features/desktop.nix
    ../features/dev.nix
    ../features/native.nix
    ../features/rust
    ../features/rust/session.nix
    ../git.nix
    ../desktop-home
  ];

  home.stateVersion = "25.11";
}
