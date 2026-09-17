{ pkgs, ... }:
{
  home.pointerCursor = {
    package = pkgs.openzone-cursors;
    name = "OpenZone_White_Slim";
    size = 24;
    gtk.enable = true;
  };

  gtk.enable = true;
}
