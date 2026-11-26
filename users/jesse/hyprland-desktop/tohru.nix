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
  package = upstreamPackage;
  voiceCudaCache = "${config.xdg.cacheHome}/tohru/cuda-cache";
  voicePython = pkgs.writeShellScript "tohru-voice-python" ''
    export CUDA_CACHE_PATH=${lib.escapeShellArg voiceCudaCache}
    exec ${pkgs.qwen3-tts-python}/bin/python3 "$@"
  '';
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
          voiceChat = "quick";
          quickVoice = {
            transport = "api";
          };
        };
        voice = {
          enable = true;
          vadModel = "${models}/silero-vad/silero-vad-v6.2.3.onnx";
          asrModel = "${models}/voice-asr";
          turnModel = "${models}/voice-turn/smart-turn-v3.2-cpu.onnx";
        };
        tts.model = "${models}/voice-kokoro";
        voiceProfiles = lib.mkIf (package != null) {
          # The user units may not see MODEL_ROOT from the session variables.
          modelRoot = config.services.local-models.root;
          high = {
            enable = true;
            python = "${voicePython}";
            ttsModel = "voice-tomoko";
            ttsSpeaker = "kuroki_tomoko";
          };
        };
      };
  };

  home.packages = [ pkgs.grimblast ];
  home.sessionVariables.XDG_SCREENSHOTS_DIR = "${config.home.homeDirectory}/Pictures/Screenshots";
  systemd.user.tmpfiles.rules = [
    "d %h/Pictures/Screenshots - - - -"
    "d ${voiceCudaCache} - - - -"
  ];
}
