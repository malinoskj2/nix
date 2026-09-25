{
  config,
  lib,
  pkgs,
  ...
}:
let
  name = "Couture";
  inherit (config.palette) glass opacity;
  palette = config.palette.mocha;
  icons = pkgs.callPackage ./icons.nix { inherit name palette; };
  # GTK3 can't parse #rrggbbaa, so each background at each glass level is its own alpha().
  glassColors =
    lib.concatMap
      (
        color:
        lib.mapAttrsToList (
          level: percent: "@define-color ${color}_${level} alpha(@${color}, ${opacity percent});"
        ) glass
      )
      [
        "base"
        "mantle"
        "crust"
      ];
  colors = pkgs.writeText "colors.css" (
    lib.concatLines (
      lib.mapAttrsToList (color: hex: "@define-color ${color} #${hex};") palette ++ glassColors
    )
  );
  # GTK resolves the stylesheet's relative imports and images from its real path, so the files
  # share one directory instead of being linked in one by one.
  theme = pkgs.runCommand "${name}-gtk-3.0" { } ''
    mkdir $out
    cp ${./gtk.css} $out/gtk.css
    cp ${colors} $out/colors.css
    cp ${./sunset-cloud.svg} $out/sunset-cloud.svg
    cp ${./sunset-cloud-2x.svg} $out/sunset-cloud-2x.svg
  '';
in
{
  # GTK always searches XDG_DATA_HOME, whatever XDG_DATA_DIRS the portal's service gets.
  xdg.dataFile = {
    "themes/${name}/gtk-3.0".source = theme;
    "icons/${name}".source = "${icons}/share/icons/${name}";
    "icons/${name}-Papirus-Dark".source = "${icons}/share/icons/${name}-Papirus-Dark";
  };

  # hyprsheet sizes the chooser from the app that opened it. When it can't tell which app that was,
  # GTK reopens it at its saved size, and this one gives a 900x560 window.
  dconf.settings."org/gtk/settings/file-chooser".window-size = lib.hm.gvariant.mkTuple [
    900
    506
  ];

  # Hyprland's portal has no file chooser, so every app's picker is this GTK3 dialog. Only this
  # process loads the theme.
  xdg.configFile."systemd/user/xdg-desktop-portal-gtk.service.d/theme.conf".text = ''
    [Service]
    Environment=GTK_THEME=${name}
  '';
}
