{ pkgs, ... }:

let
  # Verify both values with `id -un` and Directory Service before activation.
  username = "jmalinosky";
  homeDirectory = "/Users/${username}";
in
{
  nixpkgs.hostPlatform = "aarch64-darwin";

  # Determinate Nix owns the installation, daemon, and nix.conf.
  nix.enable = false;

  # This describes an existing local account; nix-darwin must not create it or
  # change any of its identity fields.
  system.primaryUser = username;
  users.users.${username}.home = homeDirectory;

  fonts.packages = with pkgs; [
    fira-code
    nerd-fonts.fira-code
    fira-mono
    lato
  ];

  homebrew = {
    enable = true;
    onActivation = {
      cleanup = "none";
      autoUpdate = false;
      upgrade = false;
    };
    casks = [
      "chromium"
      "google-chrome"
      "obs"
    ];
  };

  home-manager.users.${username} = {
    imports = [ ../../users/jesse/darwin.nix ];
    home = {
      inherit username homeDirectory;
    };
  };

  # New-install compatibility baselines. Do not bump these during upgrades.
  system.stateVersion = 7;
}
