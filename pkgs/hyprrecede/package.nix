{
  hyprland,
  hyprlandPlugins,
  lib,
}:

let
  # The plugin hooks Hyprland internals, so a clean build against a new version proves nothing.
  supportedHyprlandVersions = [ "0.56.2" ];
in
assert lib.assertMsg (lib.elem hyprland.version supportedHyprlandVersions) (
  "hyprrecede was checked against Hyprland "
  + "${lib.concatStringsSep ", " supportedHyprlandVersions}, not ${hyprland.version}; "
  + "re-check it against the new source and update this assertion."
);
hyprlandPlugins.mkHyprlandPlugin {
  pluginName = "hyprrecede";
  version = "1.0";

  src = ./.;

  buildPhase = ''
    runHook preBuild
    $CXX -shared -fPIC -O2 -std=c++2b ${lib.optionalString hyprland.stdenv.cc.isGNU "--no-gnu-unique"} \
      main.cpp -o libhyprrecede.so \
      $(pkg-config --cflags pixman-1 libdrm hyprland pangocairo libinput libudev wayland-server xkbcommon)
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 libhyprrecede.so $out/lib/libhyprrecede.so
    runHook postInstall
  '';

  meta = {
    description = "Tilts, shades and blurs the windows behind a modal layer while it is open";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
