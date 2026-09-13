{ hyprlandPluginsSrc }:
self: super: {
  otf-apple = super.callPackage ./../derivations/otf-apple.nix { };
  hyprbars = super.callPackage ./../derivations/hyprbars.nix {
    src = "${hyprlandPluginsSrc}/hyprbars";
  };
  hyprfocus = super.callPackage ./../derivations/hyprfocus.nix { };
}
