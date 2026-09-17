# The config directory is versioned, so its name is derived from the installed package.
{ lib, pkgs, ... }:
let
  datagrip = pkgs.unstable.jetbrains.datagrip;
  configDir = "JetBrains/DataGrip${lib.versions.majorMinor datagrip.version}";
in
{
  home.packages = [ datagrip ];

  xdg.configFile."${configDir}/extensions/com.intellij/startup/glass-header.groovy".source =
    ./glass-header.groovy;
}
