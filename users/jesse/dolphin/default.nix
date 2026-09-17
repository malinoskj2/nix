# Dolphin with Catppuccin glass theming, set up to work outside a Plasma session.
{ config, pkgs, ... }:
let
  inherit (config) palette;

  iconTheme = "Papirus-Dark-Catppuccin";
  kvantumTheme = "catppuccin-mocha-mauve-glass";
  viewFont = "sf-pro-text-dolphin";
  viewFontFamily = "SF Pro Text Dolphin";

  papirus = pkgs.catppuccin-papirus-folders.override {
    flavor = "mocha";
    accent = "peach";
  };

  dolphin = pkgs.callPackage ./package.nix { inherit iconTheme palette viewFontFamily; };

  icons = pkgs.callPackage ./icons.nix {
    inherit palette papirus;
    name = iconTheme;
  };
in
{
  home.packages = [
    dolphin
    pkgs.kdePackages.breeze-icons
    papirus
    icons
  ];

  xdg.dataFile."fonts/${viewFont}".source = pkgs.callPackage ./view-font.nix {
    family = viewFontFamily;
    name = viewFont;
  };

  xdg.configFile = {
    "Kvantum/${kvantumTheme}".source = pkgs.callPackage ./kvantum-theme.nix {
      inherit palette;
      catppuccin-kvantum = config.catppuccin.sources.kvantum;
      name = kvantumTheme;
    };

    "Kvantum/kvantum.kvconfig".text = ''
      [General]
      theme=${kvantumTheme}
    '';

    # Without a menu file, kbuildsycoca finds no apps and "Open With" stays empty outside Plasma.
    "menus/applications.menu".text = ''
      <!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
        "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">
      <Menu>
        <Name>Applications</Name>
        <DefaultAppDirs/>
        <DefaultDirectoryDirs/>
        <Include><All/></Include>
      </Menu>
    '';
  };
}
