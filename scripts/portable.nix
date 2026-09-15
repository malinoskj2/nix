{ lib, pkgs, ... }:

let
  portableScripts = {
    aiUsage = pkgs.writeShellApplication {
      name = "ai-usage";
      runtimeInputs = with pkgs; [
        coreutils
        curl
        jq
      ];
      text = builtins.readFile ./ai-usage;
    };

    gitCommitu = pkgs.writeShellApplication {
      name = "git-commitu";
      runtimeInputs = [ pkgs.git ];
      text = builtins.readFile ./git-commitu.sh;
    };

    gitOpen = pkgs.writeShellApplication {
      name = "git-open";
      runtimeInputs =
        with pkgs;
        [
          git
          gnused
        ]
        ++ lib.optionals stdenv.hostPlatform.isLinux [ xdg-utils ];
      text = builtins.readFile ./git-open.sh;
    };

    pubip = pkgs.writeShellApplication {
      name = "pubip";
      runtimeInputs = [ pkgs.curl ];
      text = builtins.readFile ./pubip.sh;
    };
  };
in
{
  _module.args.portableScripts = portableScripts;
  home.packages = builtins.attrValues portableScripts;
}
