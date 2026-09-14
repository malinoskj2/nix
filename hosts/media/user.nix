# User — declarative, key-only login.
{ pkgs, ... }:

{
  # Declarative accounts only: no passwd/useradd drift on a box that faces the
  # internet. jesse has no password; login is SSH key only.
  users.mutableUsers = false;

  users.users.jesse = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILCX5iegVWpd68KSOASrp5Ru1f2qmm/ifv2Lm5XqOEcd jesse"
    ];
  };

  programs.zsh.enable = true;

  security.sudo.wheelNeedsPassword = false;
}
