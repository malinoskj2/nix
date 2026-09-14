# Desktop user baseline — shared jesse account for desktop hosts (home, katana).
{ pkgs, ... }:
{
  users.users.jesse = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "network"
      "video"
      "audio"
      "disk"
      "networkmanager"
      "systemd-journal"
    ];
    shell = pkgs.zsh;
  };
}
