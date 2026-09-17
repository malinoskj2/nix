{
  services.openssh = {
    enable = true;

    settings = {
      KbdInteractiveAuthentication = false;
      LoginGraceTime = 20;
      MaxAuthTries = 3;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };
}
