# User — declarative, key-only login.
{ pkgs, secrets, ... }:

{
  # Declarative accounts only: no passwd/useradd drift on a box that faces the
  # internet. Password comes from /secret/secrets.nix (used for sudo, not SSH).
  users.mutableUsers = false;

  users.users.jesse = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
    shell = pkgs.zsh;
    password = secrets.password;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILCX5iegVWpd68KSOASrp5Ru1f2qmm/ifv2Lm5XqOEcd jesse"
    ];
  };

  programs.zsh.enable = true;

  # sudo still needs the password above — keep it that way on an exposed host.
  security.sudo.wheelNeedsPassword = true;
}
