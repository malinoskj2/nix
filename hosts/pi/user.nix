# User
{ users, secrets, ... }:

{
  users = {
    users.pi = {
      isNormalUser = true;
      password = secrets.password;
      extraGroups = [ "wheel" "docker" ];
    };
  };
}
