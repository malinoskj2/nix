# User
_:

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
