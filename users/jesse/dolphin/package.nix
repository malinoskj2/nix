{
  catppuccin-kde,
  iconTheme,
  kdePackages,
  lib,
  linkFarm,
  makeWrapper,
  palette,
  symlinkJoin,
  viewFontFamily,
  writeText,
}:

let
  qtFont = family: size: "${family},${toString size},-1,5,400,0,0,0,0,0,0,0,0,0,0,1";
  uiFont = qtFont "SF Pro Text";

  catppuccinKde = catppuccin-kde.override {
    flavour = [ "mocha" ];
    accents = [ "mauve" ];
    winDecStyles = [ "modern" ];
  };

  # Read-only defaults layered under ~/.config through XDG_CONFIG_DIRS, so Dolphin still
  # writes its own settings there. KConfig merges kdeglobals across these directories.
  defaults = linkFarm "dolphin-defaults" {
    kdeglobals = writeText "kdeglobals" (
      lib.generators.toINI { } {
        General = {
          font = uiFont 10;
          menuFont = uiFont 10;
          toolBarFont = uiFont 10;
          smallestReadableFont = uiFont 8;
          fixed = qtFont "FiraCode Nerd Font" 10;
        };

        Icons.Theme = iconTheme;
      }
    );

    dolphinrc = writeText "dolphinrc" (
      lib.generators.toINI { } {
        IconsMode = {
          IconSize = 48;
          PreviewSize = 48;
          UseSystemFont = false;
          ViewFont = qtFont viewFontFamily 10;
        };
      }
    );
  };

  colors = linkFarm "dolphin-colors" {
    kdeglobals = "${catppuccinKde}/share/color-schemes/CatppuccinMochaMauve.colors";
  };

  # The Places panel and dock separator paint nothing themselves, so they'd show the window glass.
  styleSheet = writeText "dolphin.qss" ''
    PlacesPanel { background-color: #${palette.mocha.mantle}; }
    QMainWindow::separator { background-color: #${palette.mocha.mantle}; }
  '';

  qtPlugins = lib.makeSearchPath kdePackages.qtbase.qtPluginPrefix [
    kdePackages.plasma-integration
    kdePackages.qtstyleplugin-kvantum
    kdePackages.kio-extras
    kdePackages.ffmpegthumbs
    kdePackages.kdegraphics-thumbnailers
    kdePackages.qtimageformats
    kdePackages.qtsvg
  ];
in
# The theme goes in Qt flags, not QT_* variables, so apps opened from Dolphin don't inherit it.
symlinkJoin {
  name = "dolphin-themed";
  paths = [ kdePackages.dolphin ];
  nativeBuildInputs = [ makeWrapper ];

  postBuild = ''
    wrapProgram $out/bin/dolphin \
      --prefix QT_PLUGIN_PATH : ${qtPlugins} \
      --prefix XDG_CONFIG_DIRS : ${defaults}:${colors} \
      --add-flags "-platformtheme kde -style kvantum -stylesheet ${styleSheet}"

    service=share/dbus-1/services/org.kde.dolphin.FileManager1.service
    rm $out/$service
    substitute ${kdePackages.dolphin}/$service $out/$service \
      --replace-fail ${kdePackages.dolphin}/bin/dolphin $out/bin/dolphin
  '';
}
