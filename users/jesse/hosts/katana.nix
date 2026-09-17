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
    ../git.nix
  ];

  home.stateVersion = "25.11";
}
