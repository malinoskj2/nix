_:

{
  networking = {
    hostName = "home";

    # Noctalia's network integration talks to NetworkManager over D-Bus.
    # Let NetworkManager own the interfaces and create the wired DHCP profile.
    networkmanager.enable = true;

    firewall.enable = false;
  };
}
