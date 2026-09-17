# jesse's account. Hosts add groups that only make sense there.
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
    extraGroups = [
      "wheel"
    ]
    ++ ifTheyExist [
      "docker"
      "networkmanager"
    ];
    openssh.authorizedKeys.keys = lib.splitString "\n" (lib.fileContents ./ssh.pub);
  };

  programs.zsh.enable = true;
}
