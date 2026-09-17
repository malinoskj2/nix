# Shared by every host's profile: palette, session and the core program
# modules. Profiles add features and declare their stateVersion.
{
  imports = [
    ../palette.nix
    ./session.nix
    ../alacritty.nix
    ../claude
    ../fastfetch
    ../starship.nix
    ../zed.nix
    ../zsh.nix
  ];

  programs.home-manager.enable = true;
}
