# Program
{ pkgs, ... }:

{
  programs = {
    ssh.askPassword = "";
    ssh.startAgent = true;
    zsh.enable = true;
    zsh.enableGlobalCompInit = false;
    nix-ld.enable = true;
    nix-ld.libraries = with pkgs; [
      libcap
    ];
  };
}
