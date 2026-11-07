{
  imports = [
    ../global

    ../features/admin.nix
    ../features/cli.nix
    ../features/desktop.nix
    ../features/discord-context.nix
    ../features/dev.nix
    ../features/native.nix
    ../features/rust
    ../features/rust/mold.nix

    ../agent-sandbox.nix
    ../datagrip
    ../git.nix
    ../hyprland-desktop
  ];

  services.discord-context.excludedGuilds = [
    "902708289098375209" # ogchat
  ];

  home.stateVersion = "25.11";
}
