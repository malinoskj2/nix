# Misc
{ config, pkgs, ... }:

{
  time.timeZone = "US/Eastern";
  i18n.defaultLocale = "en_US.UTF-8";

  nix = { extraOptions = "experimental-features = nix-command flakes"; };
}

