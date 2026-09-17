# Samba passwords are not declarative; set them with `smbpasswd -a <user>` on the host.
{
  services.samba = {
    enable = true;
    openFirewall = true;

    settings = {
      global = {
        "hosts allow" = "192.168.1. 127.0.0.1 localhost";
        "hosts deny" = "0.0.0.0/0";
        "map to guest" = "bad user";
        "netbios name" = "smbnix";
        "server string" = "smbnix";
      };

      public = {
        "create mask" = "0644";
        "force user" = "pi";
        "guest ok" = "yes";
        path = "/media";
        "read only" = "no";
      };
    };
  };
}
