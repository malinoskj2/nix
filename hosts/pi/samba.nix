# Samba passwords are not declarative: run `smbpasswd -a <user>` on the host.
{
  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "server string" = "smbnix";
        "netbios name" = "smbnix";
        "hosts allow" = "192.168.1. 127.0.0.1 localhost";
        "hosts deny" = "0.0.0.0/0";
        "map to guest" = "bad user";
      };
      public = {
        path = "/media";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0644";
        "force user" = "pi";
      };
    };
  };
}
