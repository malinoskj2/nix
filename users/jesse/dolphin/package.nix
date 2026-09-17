{
  lib,
  kdePackages,
  catppuccin-kde,
  linkFarm,
  makeWrapper,
  symlinkJoin,
  writeText,
  palette,
  iconTheme,
  viewFontFamily,
}:

let
  qtFont = family: size: "${family},${toString size},-1,5,400,0,0,0,0,0,0,0,0,0,0,1";

  catppuccinKde = catppuccin-kde.override {
    flavour = [ "mocha" ];
    accents = [ "mauve" ];
    winDecStyles = [ "modern" ];
  };

  # Read-only defaults layered under ~/.config via XDG_CONFIG_DIRS, so Dolphin can still write its
  # own settings there. KConfig merges kdeglobals across these directories.
  settings = linkFarm "dolphin-defaults" {
    kdeglobals = writeText "kdeglobals" (
      lib.generators.toINI { } {
        General = {
          font = qtFont "SF Pro Text" 10;
          menuFont = qtFont "SF Pro Text" 10;
          toolBarFont = qtFont "SF Pro Text" 10;
          smallestReadableFont = qtFont "SF Pro Text" 8;
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

  # Places panel and the dock separator paint nothing themselves, so they'd show the window glass.
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
# Theme is passed as Qt flags rather than QT_* env vars so apps opened from Dolphin don't inherit it.
symlinkJoin {
  name = "dolphin-themed";
  paths = [ kdePackages.dolphin ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/dolphin \
      --prefix QT_PLUGIN_PATH : ${qtPlugins} \
      --prefix XDG_CONFIG_DIRS : ${settings}:${colors} \
      --add-flags "-platformtheme kde -style kvantum -stylesheet ${styleSheet}"

    service=share/dbus-1/services/org.kde.dolphin.FileManager1.service
    rm $out/$service
    substitute ${kdePackages.dolphin}/$service $out/$service \
      --replace-fail ${kdePackages.dolphin}/bin/dolphin $out/bin/dolphin
  '';
}
