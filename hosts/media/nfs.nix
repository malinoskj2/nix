let
  lanInterface = "enp4s0";
  client = "192.168.1.131";
  nfsRule = "${lanInterface} -s ${client} -p tcp --dport 2049 -j nixos-fw-accept";
in
{
  services.nfs = {
    server = {
      enable = true;
      exports = ''
        /mnt/media3 ${client}(rw,sync,no_subtree_check,root_squash,sec=sys)
      '';
    };
    # NFSv4 needs only port 2049; v3's rpcbind and mountd stay behind the firewall.
    settings.nfsd = {
      udp = false;
      vers3 = false;
    };
  };

  # Without the disk, writes would land in the empty mountpoint on the root disk.
  systemd.services.nfs-server.unitConfig.RequiresMountsFor = [ "/mnt/media3" ];

  networking.firewall = {
    extraCommands = "iptables -A nixos-fw -i ${nfsRule}";
    extraStopCommands = "iptables -D nixos-fw -i ${nfsRule} || true";
  };
}
