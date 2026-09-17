# DataGrip with a startup script that makes the editor header translucent. The
# script's directory is versioned, so it is derived from the installed package.
{ lib, pkgs, ... }:
let
  datagrip = pkgs.unstable.jetbrains.datagrip;
in
{
  home.packages = [ datagrip ];

  home.file.".config/JetBrains/DataGrip${lib.versions.majorMinor datagrip.version}/extensions/com.intellij/startup/glass-header.groovy".source =
    ./glass-header.groovy;
}
