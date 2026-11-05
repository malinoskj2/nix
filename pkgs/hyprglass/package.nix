{
  fetchFromGitHub,
  hyprland,
  hyprlandPlugins,
  lib,
}:

let
  # Each hyprglass release targets one Hyprland release, and a patch touches its layer hook.
  supportedHyprlandVersions = [ "0.56.2" ];
in
assert lib.assertMsg (lib.elem hyprland.version supportedHyprlandVersions) (
  "hyprglass and its patches were checked against Hyprland "
  + "${lib.concatStringsSep ", " supportedHyprlandVersions}, not ${hyprland.version}; "
  + "move to the matching hyprglass release, re-check the patches and update this assertion."
);
hyprlandPlugins.mkHyprlandPlugin (finalAttrs: {
  pluginName = "hyprglass";
  version = "0.8.1";

  src = fetchFromGitHub {
    owner = "hyprnux";
    repo = "hyprglass";
    tag = "v${finalAttrs.version}";
    hash = "sha256-yUU0gKu1CXqpUQBtyb3IWNBYZ1bCAm99mfTUV7ceJyg=";
  };

  # layer-shape.patch shapes layer glass to each piece of the requested blur region and adds the
  # per-layer corner_radius, rounding_power, rim_light, rim_shadow and gleam_* options to hg.layer.
  # panel-contrast.patch reports how bright the background behind the panel is to j2bar, so the
  # panel's glass and ink adapt together.
  patches = [
    ./layer-shape.patch
    ./panel-contrast.patch
  ];

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
})
