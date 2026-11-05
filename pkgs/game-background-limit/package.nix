{
  game-background-engine,
  hyprland,
  lib,
  linkFarm,
  makeWrapper,
  pkgsi686Linux,
  python3,
  stdenvNoCC,
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
  # The dynamic loader expands $PLATFORM to x86_64 or i686, so one LD_PRELOAD
  # entry serves both 64-bit and 32-bit game processes.
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
    runHook preCheck
    python -m unittest discover -s tests -v
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm644 game_background_limit.py $out/lib/game_background_limit.py
    install -Dm644 automatic.py $out/lib/automatic.py
    ln -s ${manifests} $out/share
    ln -s ${preload} $out/preload
    makeWrapper ${python3}/bin/python3 $out/bin/game-background-limit \
      --add-flags $out/lib/game_background_limit.py \
      --set GAME_BACKGROUND_LIB '${library}' \
      --set GAME_BACKGROUND_DATA ${manifests} \
      --set GAME_BACKGROUND_HYPRCTL ${hyprland}/bin/hyprctl
    runHook postInstall
  '';
  meta = {
    description = "Limit unfocused Steam games to 10 FPS without an overlay";
    mainProgram = "game-background-limit";
    platforms = [ "x86_64-linux" ];
  };
}
