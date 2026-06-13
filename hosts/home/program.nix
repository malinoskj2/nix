# Program
{ config, pkgs, ... }:

{
  programs.ssh.askPassword = "";
  programs.ssh.startAgent = true;
  programs.zsh.enable = true;
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;
  };
  programs.gamemode.enable = true;
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    libcap
  ];
}
