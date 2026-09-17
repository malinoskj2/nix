{
  config,
  lib,
  pkgs,
  ...
}:
let
  ifTheyExist = groups: lib.filter (group: config.users.groups ? ${group}) groups;
in
{
  users.users.jesse = {
    isNormalUser = true;
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = lib.splitString "\n" (lib.fileContents ./ssh.pub);
    extraGroups = [
      "wheel"
    ]
    ++ ifTheyExist [
      "docker"
      "networkmanager"
    ];
  };

  programs.zsh.enable = true;
}
