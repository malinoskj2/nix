# An enabled, key-only sshd for internet-facing hosts; each host sets its own port and AllowUsers.
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
