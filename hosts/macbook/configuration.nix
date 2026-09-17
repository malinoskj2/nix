# macbook: Apple-silicon MacBook on nix-darwin, with a user-scoped Home Manager
# profile. Determinate Nix owns the Nix installation.
{ inputs, pkgs, ... }:

let
  # Verify both values with `id -un` and Directory Service before activation.
  username = "jmalinosky";
  homeDirectory = "/Users/${username}";
in
{
  imports = [
    inputs.home-manager.darwinModules.home-manager
    ../common/home-manager.nix
  ];

  nixpkgs.hostPlatform = "aarch64-darwin";

  # Determinate Nix owns the daemon and nix.conf.
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

  # Home Manager takes username and home directory from the account above.
  home-manager.users.${username} = ../../users/jesse/hosts/macbook.nix;

  # New-install compatibility baseline. Do not bump it during upgrades.
  system.stateVersion = 7;
}
