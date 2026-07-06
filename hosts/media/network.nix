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
      allowedTCPPorts = [
        80
        443
        32400
      ];
    };
  };
}
