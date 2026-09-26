{
  fetchFromGitHub,
  hyprland,
  hyprlandPlugins,
  lib,
}:

let
  # Each hyprglass release targets one Hyprland release, and the patch touches its layer hook.
  supportedHyprlandVersions = [ "0.56.2" ];
in
assert lib.assertMsg (lib.elem hyprland.version supportedHyprlandVersions) (
  "hyprglass and layer-shape.patch were checked against Hyprland "
  + "${lib.concatStringsSep ", " supportedHyprlandVersions}, not ${hyprland.version}; "
  + "move to the matching hyprglass release, re-check the patch and update this assertion."
);
hyprlandPlugins.mkHyprlandPlugin {
  pluginName = "hyprglass";
  version = "0.8.1";

  src = fetchFromGitHub {
    owner = "hyprnux";
    repo = "hyprglass";
    tag = "v0.8.1";
    hash = "sha256-yUU0gKu1CXqpUQBtyb3IWNBYZ1bCAm99mfTUV7ceJyg=";
  };

  # Shapes layer glass to each separate piece of the requested blur region, scaled with the layer
  # without rounding so its rim stays on the content's edge while the layer scales in, raises the
  # region's rect limit, and adds per-layer corner_radius, rounding_power, rim_light, rim_shadow
  # and the gleam_* options to hg.layer. The gleam sweeps the top rim once when a layer maps,
  # damaging it only until then.
  patches = [ ./layer-shape.patch ];

  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 hyprglass.so $out/lib/libhyprglass.so
    runHook postInstall
  '';

  meta = {
    description = "Liquid Glass effect for Hyprland windows and layers";
    homepage = "https://github.com/hyprnux/hyprglass";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
