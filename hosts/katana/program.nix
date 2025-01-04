# Program
{ config, pkgs, ... }:

{
  programs.ssh.askPassword = "";
  programs.ssh.startAgent = true;
  programs.zsh.enable = true;
  programs.nix-ld.enable = true;
}

