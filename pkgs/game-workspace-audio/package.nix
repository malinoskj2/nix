{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
  hyprland,
  pipewire,
  wireplumber,
}:
stdenvNoCC.mkDerivation {
  pname = "game-workspace-audio";
  version = "1";
  src = ./.;
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ python3 ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    python -m unittest discover -s tests -v
  '';
  installPhase = ''
    install -Dm644 game_workspace_audio.py $out/lib/game_workspace_audio.py
    makeWrapper ${python3}/bin/python3 $out/bin/game-workspace-audio \
      --add-flags $out/lib/game_workspace_audio.py \
      --set GAME_AUDIO_HYPRCTL ${hyprland}/bin/hyprctl \
      --set GAME_AUDIO_PW_DUMP ${pipewire}/bin/pw-dump \
      --set GAME_AUDIO_WPCTL ${wireplumber}/bin/wpctl
  '';
  meta = {
    description = "Mute Steam games while Hyprland workspace 5 is hidden";
    mainProgram = "game-workspace-audio";
    platforms = lib.platforms.linux;
  };
}
