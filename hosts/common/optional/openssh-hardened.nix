# Key-only sshd for internet-facing hosts; hosts set their own port and AllowUsers.
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      MaxAuthTries = 3;
      LoginGraceTime = 20;
    };
  };
}
