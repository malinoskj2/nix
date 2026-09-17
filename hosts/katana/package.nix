# Package
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.read-edid ];
}
