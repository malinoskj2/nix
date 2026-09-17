# Imported by every NixOS host.
{ lib, pkgs, ... }:
{
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
