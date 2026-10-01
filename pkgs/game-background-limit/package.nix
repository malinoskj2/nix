{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
  hyprland,
  mangohud,
  pkgsi686Linux,
  linkFarm,
  runCommand,
}:
let
  # Pressure-vessel replaces LD_LIBRARY_PATH, so use explicit architecture
  # tokens in the preload path. The shim locates its adjacent library via
  # realpath, which follows these symlinks to the original MangoHud outputs.
  preload = linkFarm "mangohud-game-preload" [
    {
      name = "x86_64/libMangoHud_shim.so";
      path = "${mangohud}/lib/mangohud/libMangoHud_shim.so";
    }
    {
      name = "i686/libMangoHud_shim.so";
      path = "${pkgsi686Linux.mangohud}/lib/mangohud/libMangoHud_shim.so";
    }
  ];
  shim =
    if stdenvNoCC.hostPlatform.isx86_64 then
      "${preload}/\${PLATFORM}/libMangoHud_shim.so"
    else
      "${mangohud}/lib/mangohud/libMangoHud_shim.so";
  launcher = runCommand "mangohud-game-launcher" { nativeBuildInputs = [ python3 ]; } ''
    mkdir -p $out/bin
    cp ${mangohud}/bin/mangohud $out/bin/mangohud
    chmod u+w $out/bin/mangohud
    python - "$out/bin/mangohud" '${shim}' <<'PY'
    import pathlib, sys
    path = pathlib.Path(sys.argv[1])
    original = 'MANGOHUD_LIB_NAME="libMangoHud_shim.so"'
    text = path.read_text()
    if original not in text:
        raise SystemExit("Review the MangoHud launcher: preload assignment changed")
    path.write_text(text.replace(original, "MANGOHUD_LIB_NAME='" + sys.argv[2] + "'"))
    PY
  '';
in
stdenvNoCC.mkDerivation {
  pname = "game-background-limit";
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
    install -Dm644 game_background_limit.py $out/lib/game_background_limit.py
    makeWrapper ${python3}/bin/python3 $out/bin/game-background-limit \
      --add-flags $out/lib/game_background_limit.py \
      --set GAME_BACKGROUND_MANGOHUD ${launcher}/bin/mangohud \
      --set GAME_BACKGROUND_HYPRCTL ${hyprland}/bin/hyprctl
  '';
  meta = {
    description = "Hide MangoHud and limit an unfocused Hyprland game to 10 FPS";
    mainProgram = "game-background-limit";
    platforms = lib.platforms.linux;
  };
}
