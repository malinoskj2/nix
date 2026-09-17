# Misc
_:

{
  time.timeZone = "America/New_York";

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 21d";
  };
  nix.settings.auto-optimise-store = true;
}
