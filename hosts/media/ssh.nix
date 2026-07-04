# SSH — key-only, hardened for eventual internet exposure.
{ ... }:

{
  services.openssh = {
    enable = true;
    # Non-default port cuts the bulk of untargeted scan noise. Update the
    # firewall/reverse-proxy and your ~/.ssh/config to match.
    ports = [ 2222 ];
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      X11Forwarding = false;
      AllowUsers = [ "jesse" ];
      MaxAuthTries = 3;
      LoginGraceTime = 20;
    };
  };
}
