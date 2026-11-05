{
  lib,
  libGL,
  python3,
  stdenv,
  vulkan-headers,
}:
let
  bits = toString stdenv.hostPlatform.parsed.cpu.bits;
  flags = "-std=c++17 -Wall -Wextra -Werror -O2 -pthread";
in
stdenv.mkDerivation {
  pname = "game-background-engine";
  version = "1";
  src = ./.;
  buildInputs = [ vulkan-headers ];
  nativeCheckInputs = [ python3 ];
  buildPhase = ''
    runHook preBuild
    $CXX ${flags} -fno-exceptions -fno-rtti -fPIC -shared engine.cpp -Wl,--as-needed -ldl -o libgame-background.so
    $CXX ${flags} test.cpp -ldl -o engine-test
    runHook postBuild
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    LD_LIBRARY_PATH=${libGL}/lib ./engine-test
    python test_guards.py
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 libgame-background.so $out/lib/libgame-background.so
    install -Dm644 LICENSE $out/share/doc/game-background-engine/LICENSE
    install -Dm644 SOURCES.md $out/share/doc/game-background-engine/SOURCES.md
    mkdir -p $out/share/vulkan/implicit_layer.d
    cat > $out/share/vulkan/implicit_layer.d/background-${bits}.json <<EOF
    {
      "file_format_version": "1.0.0",
      "layer": {
        "name": "VK_LAYER_JESSE_background_limit_${bits}",
        "type": "GLOBAL",
        "api_version": "1.3.0",
        "library_path": "$out/lib/libgame-background.so",
        "implementation_version": "1",
        "description": "Unfocused game frame limiter",
        "functions": {
          "vkGetInstanceProcAddr": "background_GetInstanceProcAddr",
          "vkGetDeviceProcAddr": "background_GetDeviceProcAddr"
        },
        "enable_environment": { "GAME_BACKGROUND_VULKAN": "1" },
        "disable_environment": { "GAME_BACKGROUND_LIMIT": "0" }
      }
    }
    EOF
    runHook postInstall
  '';
  meta = {
    description = "Vulkan, GLX and EGL presentation hooks for background frame limiting";
    platforms = lib.platforms.linux;
    license = lib.licenses.mit;
  };
}
