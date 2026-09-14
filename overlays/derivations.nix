self: super: {
  otf-apple = super.callPackage ./../derivations/otf-apple.nix { };
  # The coupled Hyprland overlay is ordered before this one in flake.nix.
  hyprfocus = super.callPackage ./../derivations/hyprfocus.nix { };
}
