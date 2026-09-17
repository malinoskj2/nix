# nh, pointed at this flake's checkout in jesse's home.
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
