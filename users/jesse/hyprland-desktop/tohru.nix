{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  # Tohru is only built and tested for x86_64-linux; other hosts run Hyprland without a shell.
  upstreamPackage = inputs.tohru.packages.${system}.default or null;
  # Carry Tohru commits 73b4ed3 and 3951bfb until the upstream input includes direct bot chat delivery.
  package =
    if upstreamPackage == null then
      null
    else
      upstreamPackage.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./tohru-orca-chat.patch ];
      });
in
{
  imports = [ inputs.tohru.homeManagerModules.default ];

  programs.tohru = {
    enable = package != null;
    package = lib.mkIf (package != null) package;
    systemd.enable = true;
    polkit.enable = true;
    lock.style = "flooded-monolith";
    settings.bar.preferred_output = config.desktop.monitors.main.output;
    assistant =
      let
        models = "${config.services.local-models.root}/by-name";
      in
      {
        orcaBot = {
          enable = true;
          bot = "Tohru";
          voiceChat = "home";
        };
        voice = {
          enable = true;
          vadModel = "${models}/silero-vad/silero-vad-v6.2.3.onnx";
          asrModel = "${models}/voice-asr";
          turnModel = "${models}/voice-turn/smart-turn-v3.2-cpu.onnx";
        };
        tts.model = "${models}/voice-kokoro";
      };
  };

  home.packages = [ pkgs.grimblast ];
  home.sessionVariables.XDG_SCREENSHOTS_DIR = "${config.home.homeDirectory}/Pictures/Screenshots";
  systemd.user.tmpfiles.rules = [ "d %h/Pictures/Screenshots - - - -" ];
}
