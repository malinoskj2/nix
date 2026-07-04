# Network
{ ... }:

{
  networking = {
    hostName = "media";
    useDHCP = true;
    nameservers = [
      "1.1.1.1"
      "9.9.9.9"
    ];

    firewall = {
      enable = true;
      allowPing = false;
      # SSH is on a non-default port (see ssh.nix). 80/443 are opened here so a
      # reverse proxy (Caddy/Traefik in Docker) can terminate TLS once exposed.
      allowedTCPPorts = [
        80
        443
      ];
      # Everything else the media stack needs should be published only on the
      # LAN/loopback by Docker, or fronted by the reverse proxy — do not open
      # per-app ports to the internet here.
    };
  };
}
