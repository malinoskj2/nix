{ config, pkgs, ... }:

let
  inherit (config) palette;
  kvantumTheme = "catppuccin-mocha-mauve-glass";
  iconTheme = "Papirus-Dark-Catppuccin";
  viewFontFamily = "SF Pro Text Dolphin";

  papirus = pkgs.catppuccin-papirus-folders.override {
    flavor = "mocha";
    accent = "peach";
  };
in
{
  home.packages = [
    (pkgs.callPackage ./package.nix { inherit palette iconTheme viewFontFamily; })
    pkgs.kdePackages.breeze-icons
    papirus
    (pkgs.callPackage ./icons.nix {
      inherit papirus palette;
      name = iconTheme;
    })
  ];

  xdg.dataFile."fonts/sf-pro-text-dolphin".source = pkgs.callPackage ./view-font.nix {
    family = viewFontFamily;
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
    # kbuildsycoca finds no applications without a menu file, leaving "Open With" empty outside Plasma.
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
