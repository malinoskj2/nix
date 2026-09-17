# nh, pointed at the flake checkout in jesse's home directory.
{ lib, ... }:
{
  programs.nh = {
    enable = true;
    flake = "/home/jesse/nix";

    clean = {
      enable = lib.mkDefault true;
      extraArgs = "--keep-since 7d --keep 5";
    };
  };
}
