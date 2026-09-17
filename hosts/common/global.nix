# Baseline shared by every NixOS host.
{ lib, pkgs, ... }:
{
  # The order reaches nix.conf, so this list stays unsorted.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  time.timeZone = lib.mkDefault "America/New_York";

  environment.systemPackages = with pkgs; [
    git
    vim
  ];
}
