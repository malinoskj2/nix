{
  lib,
  stdenv,
  vulkan-headers,
  python3,
  libGL,
}:
stdenv.mkDerivation {
  pname = "game-background-engine";
  version = "1";
  src = ./.;
  buildInputs = [ vulkan-headers ];
  nativeCheckInputs = [ python3 ];
  buildPhase = ''
    $CXX -std=c++17 -Wall -Wextra -Werror -O2 -fno-exceptions -fno-rtti -fPIC -shared -pthread engine.cpp -Wl,--as-needed -ldl -o libgame-background.so
    $CXX -std=c++17 -Wall -Wextra -Werror -O2 -pthread test.cpp -ldl -o engine-test
  '';
  doCheck = true;
  checkPhase = ''
    LD_LIBRARY_PATH=${libGL}/lib ./engine-test
    python test_guards.py
  '';
  installPhase = ''
    install -Dm755 libgame-background.so $out/lib/libgame-background.so
    install -Dm644 LICENSE $out/share/doc/game-background-engine/LICENSE
    install -Dm644 SOURCES.md $out/share/doc/game-background-engine/SOURCES.md
    mkdir -p $out/share/vulkan/implicit_layer.d
    cat > $out/share/vulkan/implicit_layer.d/background-${toString stdenv.hostPlatform.parsed.cpu.bits}.json <<EOF
    {
      "file_format_version": "1.0.0",
      "layer": {
        "name": "VK_LAYER_JESSE_background_limit_${toString stdenv.hostPlatform.parsed.cpu.bits}",
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
  '';
  meta = {
    description = "Vulkan, GLX and EGL presentation hooks for background frame limiting";
    platforms = lib.platforms.linux;
    license = lib.licenses.mit;
  };
}
