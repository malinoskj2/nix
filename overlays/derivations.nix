self: super: {
  otf-apple = super.callPackage ./../derivations/otf-apple.nix { };
  hyprfocus = super.callPackage ./../derivations/hyprfocus.nix { };
}
