# User
{ users, ... }:

{
  users = {
    users.pi = {
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "docker"
      ];
    };
  };
}
