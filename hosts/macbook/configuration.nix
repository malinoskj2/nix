{ inputs, pkgs, ... }:
let
  # Check the name with `id -un` and its home in Directory Service before activation.
  username = "jmalinosky";
in
{
  imports = [
    inputs.home-manager.darwinModules.home-manager

    ../common/home-manager.nix
  ];

  nixpkgs.hostPlatform = "aarch64-darwin";

  # Determinate Nix owns the daemon and nix.conf.
  nix.enable = false;

  # Not listed in users.knownUsers, so nix-darwin never creates or modifies this account.
  users.users.${username}.home = "/Users/${username}";

  fonts.packages = with pkgs; [
    fira-code
    fira-mono
    lato
    nerd-fonts.fira-code
  ];

  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = false;
      cleanup = "none";
      upgrade = false;
    };
    casks = [
      "chromium"
      "google-chrome"
      "obs"
    ];
  };

  # Home Manager takes the username and home directory from the account above.
  home-manager.users.${username} = ../../users/jesse/profiles/macbook.nix;

  system.primaryUser = username;
  system.stateVersion = 7;
}
