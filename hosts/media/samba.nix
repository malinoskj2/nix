let
  lanInterface = "enp4s0";
  lanAddress = "192.168.1.200";
  lanSubnet = "192.168.1.0/24";
  smbRule = "-i ${lanInterface} -s ${lanSubnet} -p tcp --dport 445 -j nixos-fw-accept";
in
{
  # Samba passwords are not declarative; set them with `smbpasswd -a <user>` on the host.
  services.samba = {
    enable = true;
    nmbd.enable = false;
    settings = {
      global = {
        "bind interfaces only" = "yes";
        "disable netbios" = "yes";
        "hosts allow" = lanSubnet;
        "hosts deny" = "ALL";
        # The interface name would also bind its public IPv6 addresses.
        interfaces = "${lanAddress}/24";
        "load printers" = "no";
        "map to guest" = "never";
        "restrict anonymous" = "2";
        "server min protocol" = "SMB3";
        "server string" = "media";
        "smb ports" = "445";
      };
      media3 = {
        "create mask" = "0644";
        "directory mask" = "0755";
        "hide unreadable" = "yes";
        path = "/mnt/media3";
        "read only" = "no";
        "valid users" = "jesse";
      };
    };
  };

  # Without the disk, writes would land in the empty mountpoint on the root disk.
  systemd.services.samba-smbd.unitConfig.RequiresMountsFor = [ "/mnt/media3" ];

  # The router forwards internet traffic to Caddy, and forwarded packets keep their public
  # source address, so only LAN sources on the LAN interface may reach SMB.
  networking.firewall = {
    extraCommands = "iptables -A nixos-fw ${smbRule}";
    extraStopCommands = "iptables -D nixos-fw ${smbRule} || true";
  };
}
