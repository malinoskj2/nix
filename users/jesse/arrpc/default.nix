{ pkgs, ... }:
let
  # The release's copy predates upstream's fix for Discord's current webpack layout.
  bridgeMod = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/OpenAsar/arrpc/3c4e1ce3c49926bfeb9febbaa04327b06b3a4c2c/examples/bridge_mod.js";
    hash = "sha256-xw8H4nnyQzl9WJB6ubPdGr8kjx1kA+G7ceb6jJ1eijI=";
  };
  bridge =
    pkgs.runCommand "arrpc-firefox-bridge"
      {
        nativeBuildInputs = [ pkgs.jq ];
      }
      ''
        mkdir $out
        {
          printf 'const BRIDGE = '
          {
            sed '/@bridgeMod@/,$d' ${./bridge.js}
            cat ${bridgeMod}
            sed '1,/@bridgeMod@/d' ${./bridge.js}
          } | jq -Rs .
          printf ';\n\n'
          cat ${./ArrpcBridgeChild.sys.mjs}
        } > $out/ArrpcBridgeChild.sys.mjs
      '';
in
{
  services.arrpc.enable = true;

  # Discord in Firefox has no IPC socket of its own; arRPC stands in for it, and this AutoConfig
  # feeds arRPC's activity into the discord.com tab the way its bridge mod does from the console.
  # Release Firefox only loads signed extensions, so AutoConfig is the declarative route.
  programs.firefox = {
    package = pkgs.firefox.override {
      extraPrefsFiles = [ (pkgs.replaceVars ./autoconfig.js { inherit bridge; }) ];
    };
    # Local Network Access would otherwise prompt before the tab reaches arRPC on loopback.
    policies.LocalNetworkAccess.SkipDomains = [
      "discord.com"
      "*.discord.com"
    ];
  };
}
