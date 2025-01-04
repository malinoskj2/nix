# Network
{ networking, ... }:

{
  networking = {
    hostName = "pi";
    interfaces.eth0 = { useDHCP = true; };
    nameservers = [ "1.1.1.1" ];
  };
}
