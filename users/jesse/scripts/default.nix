{ pkgs, ... }:

{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "git-commitu";
      runtimeInputs = [ pkgs.git ];
      text = builtins.readFile ./git-commitu.sh;
    })
    (pkgs.writeShellApplication {
      name = "git-open";
      runtimeInputs = with pkgs; [
        git
        gnused
        xdg-utils
      ];
      text = builtins.readFile ./git-open.sh;
    })
    (pkgs.writeShellApplication {
      name = "pubip";
      runtimeInputs = [ pkgs.curl ];
      text = builtins.readFile ./pubip.sh;
    })
    (pkgs.writeShellApplication {
      name = "find_service";
      runtimeInputs = with pkgs; [
        nmap
        gnused
        gawk
      ];
      text = builtins.readFile ./find_service.sh;
    })
    (pkgs.writeShellApplication {
      name = "ata_devs";
      runtimeInputs = with pkgs; [
        coreutils
        gnused
        gnugrep
      ];
      text = builtins.readFile ./ata_devs.sh;
    })
  ];
}
