{
  pkgs,
  portableScripts,
  ...
}:

let
  noctalia = pkgs.unstable.noctalia;

  linuxScripts = {
    ataDevs = pkgs.writeShellApplication {
      name = "ata_devs";
      runtimeInputs = with pkgs; [
        coreutils
        gnugrep
        gnused
      ];
      text = builtins.readFile ./ata_devs.sh;
    };

    battery = pkgs.writeShellApplication {
      name = "battery";
      runtimeInputs = [ pkgs.coreutils ];
      text = builtins.readFile ./battery.sh;
    };

    findService = pkgs.writeShellApplication {
      name = "find_service";
      runtimeInputs = with pkgs; [
        gawk
        gnused
        nmap
      ];
      text = builtins.readFile ./find_service.sh;
    };

    wallpaperAutopause = pkgs.writeShellApplication {
      name = "wallpaper-autopause";
      runtimeInputs = [
        noctalia
        pkgs.coreutils
        pkgs.dbus
        pkgs.glib
        pkgs.hyprland
        pkgs.jq
        pkgs.socat
        pkgs.systemd
      ];
      text = builtins.readFile ./wallpaper-autopause.sh;
    };

    wallpaperRandomize = pkgs.writeShellApplication {
      name = "wallpaper-randomize";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
        jq
      ];
      text = builtins.readFile ./wallpaper-randomize.sh;
    };

    wallpaperSelect = pkgs.writeShellApplication {
      name = "wallpaper_select";
      runtimeInputs = [
        noctalia
        pkgs.coreutils
        pkgs.findutils
        pkgs.hyprland
        pkgs.jq
        pkgs.socat
      ];
      text = builtins.readFile ./wallpaper_select.sh;
    };

    wifiConnect = pkgs.writeShellApplication {
      name = "wifi-connect";
      runtimeInputs = with pkgs; [
        coreutils
        dhcpcd
        gawk
        gnugrep
        iproute2
        iw
        procps
        util-linux
        wpa_supplicant
      ];
      text = builtins.readFile ./wifi_connect.sh;
    };
  };
in
{
  imports = [ ./portable.nix ];

  _module.args.jesseScripts = portableScripts // linuxScripts;
  home.packages = builtins.attrValues linuxScripts;
}
