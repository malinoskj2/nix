{
  imports = [
    ../global

    ../features/admin.nix
    ../features/cli.nix
    ../features/desktop.nix
    ../features/dev.nix
    ../features/native.nix
    ../features/rust

    ../datagrip
    ../git.nix
  ];

  home.stateVersion = "25.11";
}
