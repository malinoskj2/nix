{
  imports = [
    ../alacritty.nix
    ../claude
    ../fastfetch
    ../starship.nix
    ../zed.nix
    ../zsh.nix

    ./palette.nix
    ./session.nix
  ];

  programs.home-manager.enable = true;
}
