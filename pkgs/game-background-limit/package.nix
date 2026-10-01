{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
  hyprland,
  game-background-engine,
  pkgsi686Linux,
  linkFarm,
}:
let
  bits = toString stdenvNoCC.hostPlatform.parsed.cpu.bits;
  engine32 = pkgsi686Linux.game-background-engine;
  preload = linkFarm "game-background-preload" [
    {
      name = "x86_64/libgame-background.so";
      path = "${game-background-engine}/lib/libgame-background.so";
    }
    {
      name = "i686/libgame-background.so";
      path = "${engine32}/lib/libgame-background.so";
    }
  ];
  manifests = linkFarm "game-background-manifests" (
    [
      {
        name = "vulkan/implicit_layer.d/background-${bits}.json";
        path = "${game-background-engine}/share/vulkan/implicit_layer.d/background-${bits}.json";
      }
    ]
    ++ lib.optional stdenvNoCC.hostPlatform.isx86_64 {
      name = "vulkan/implicit_layer.d/background-32.json";
      path = "${engine32}/share/vulkan/implicit_layer.d/background-32.json";
    }
  );
  library =
    if stdenvNoCC.hostPlatform.isx86_64 then
      "${preload}/\${PLATFORM}/libgame-background.so"
    else
      "${game-background-engine}/lib/libgame-background.so";
in
stdenvNoCC.mkDerivation {
  pname = "game-background-limit";
  version = "2";
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
    install -Dm644 automatic.py $out/lib/automatic.py
    ln -s ${manifests} $out/share
    ln -s ${preload} $out/preload
    makeWrapper ${python3}/bin/python3 $out/bin/game-background-limit \
      --add-flags $out/lib/game_background_limit.py \
      --set GAME_BACKGROUND_LIB '${library}' \
      --set GAME_BACKGROUND_DATA ${manifests} \
      --set GAME_BACKGROUND_HYPRCTL ${hyprland}/bin/hyprctl
  '';
  meta = {
    description = "Limit unfocused Steam games to 10 FPS without an overlay";
    mainProgram = "game-background-limit";
    platforms = lib.platforms.linux;
  };
}
