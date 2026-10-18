# Samba passwords are not declarative; set them with `smbpasswd -a <user>` on the host.
let
  lanInterface = "enp4s0";
  lanAddress = "192.168.1.200";
  lanSubnet = "192.168.1.0/24";
  smbRule = "${lanInterface} -s ${lanSubnet} -p tcp --dport 445 -j nixos-fw-accept";
in
{
  services.samba = {
    enable = true;
    nmbd.enable = false;
    settings = {
      global = {
        "server string" = "media";
        # The interface name would also bind its public IPv6 addresses.
        interfaces = "${lanAddress}/24";
        "bind interfaces only" = "yes";
        "hosts allow" = lanSubnet;
        "hosts deny" = "ALL";
        "smb ports" = "445";
        "disable netbios" = "yes";
        "server min protocol" = "SMB3";
        "map to guest" = "never";
        "restrict anonymous" = "2";
        "load printers" = "no";
      };
      media3 = {
        path = "/mnt/media3";
        "valid users" = "jesse";
        "read only" = "no";
        "hide unreadable" = "yes";
        "create mask" = "0644";
        "directory mask" = "0755";
      };
    };
  };

  # Without the disk, writes would land in the empty mountpoint on the root disk.
  systemd.services.samba-smbd.unitConfig.RequiresMountsFor = [ "/mnt/media3" ];

  # The router forwards internet traffic to Caddy, and forwarded packets keep their public
  # source address, so only LAN sources on the LAN interface may reach SMB.
  networking.firewall = {
    extraCommands = "iptables -A nixos-fw -i ${smbRule}";
    extraStopCommands = "iptables -D nixos-fw -i ${smbRule} || true";
  };
}
