{
  config,
  lib,
  pkgs,
  ...
}:

let
  kp = pkgs.kdePackages;
  kvantumTheme = "catppuccin-mocha-mauve-glass";

  # Catppuccin Mocha Mauve with the top bar turned into the same crust glass as the Firefox toolbox,
  # Zed title bar and hyprbars. Kvantum paints a window with its "Window" element only when a toolbar
  # sits at the window's top-left pixel, otherwise with "Dialog". So the toolbar keeps an invisible
  # frame (dropping it puts a button there and the main window resolves to Dialog), Window carries the
  # glass alpha in the SVG, and Dialog gets an opaque element so dialogs stay solid.
  # reduce_window_opacity must be nonzero or Kvantum skips translucency, but it dims every element,
  # dialogs included, so it stays at 1% and the real alpha lives in the SVG.
  glassTheme = pkgs.runCommand kvantumTheme { nativeBuildInputs = [ pkgs.python3 ]; } ''
    mkdir $out
    python3 - ${config.catppuccin.sources.kvantum}/share/Kvantum/catppuccin-mocha-mauve/catppuccin-mocha-mauve $out/${kvantumTheme} <<'EOF'
    import re, sys
    src, dst = sys.argv[1], sys.argv[2]

    edits = {
        "%General": {
            "translucent_windows": "true",
            "reduce_window_opacity": "1",
            # Hyprland does the blur.
            "blurring": "false",
            "popup_blurring": "false",
        },
        "Toolbar": {"interior": "false", "frame.element": "tabframe"},
        "Dialog": {"interior": "true", "interior.element": "solid"},
        # Inherits Toolbar, so it needs its own opaque interior back.
        "StatusBar": {"interior": "true", "interior.element": "toolbar"},
    }
    out, section, done = [], None, set()

    def flush():
        for k, v in edits.get(section, {}).items():
            if (section, k) not in done:
                out.append(k + "=" + v)

    for line in open(src + ".kvconfig").read().splitlines():
        m = re.match(r"\[(.+)\]$", line)
        if m:
            if section is not None:
                while out and out[-1] == "":
                    out.pop()
                flush()
                out.append("")
            section = m.group(1)
        else:
            key = line.split("=", 1)[0]
            if key in edits.get(section, {}):
                line = key + "=" + edits[section][key]
                done.add((section, key))
        out.append(line)
    flush()
    open(dst + ".kvconfig", "w").write("\n".join(out) + "\n")

    svg = open(src + ".svg").read()
    glass = lambda m: m.group(0).replace("fill:#1E1E2E", "fill:#11111B;fill-opacity:0.55")
    svg = re.sub(r'<g id="window-normal-[a-z]+".*?</g>', glass, svg, flags=re.S)
    svg = re.sub(r'<rect id="window-normal"[^>]*>', glass, svg)
    svg = svg.replace(
        '<rect id="window-normal"',
        '<rect id="solid-normal" style="fill:#1E1E2E" width="46" height="46" x="767" y="254"/>\n <rect id="window-normal"',
        1,
    )
    open(dst + ".svg", "w").write(svg)
    EOF
  '';

  papirus = pkgs.catppuccin-papirus-folders.override {
    flavor = "mocha";
    accent = "peach";
  };

  iconTheme = "Papirus-Dark-Catppuccin";
  icons = pkgs.runCommand iconTheme { nativeBuildInputs = [ pkgs.python3 ]; } ''
    mkdir -p $out/share/icons/${iconTheme}
    python3 ${./papirus-catppuccin.py} ${papirus}/share/icons/Papirus-Dark $out/share/icons/${iconTheme} ${iconTheme}
  '';

  catppuccinKde = pkgs.catppuccin-kde.override {
    flavour = [ "mocha" ];
    accents = [ "mauve" ];
    winDecStyles = [ "modern" ];
  };

  # SF Pro declares an average glyph width of 1.18em (the real one is ~0.56em), and Dolphin sizes
  # icon-view cells from it, so they come out twice as wide as the names need. This copy carries the
  # real metric under its own family name and is used for the view font only.
  viewFontFamily = "SF Pro Text Dolphin";
  viewFont =
    pkgs.runCommand "sf-pro-text-dolphin"
      { nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.fonttools ])) ]; }
      ''
        mkdir $out
        python3 - "${pkgs.otf-apple}/share/fonts/opentype/SF Pro" $out <<'EOF'
        import glob, os, sys
        from fontTools.ttLib import TTFont
        for f in glob.glob(sys.argv[1] + "/SF-Pro-Text-*.otf"):
            t = TTFont(f)
            cmap, hmtx = t.getBestCmap(), t["hmtx"]
            adv = [hmtx[cmap[c]][0] for c in range(32, 127) if c in cmap]
            t["OS/2"].xAvgCharWidth = round(sum(adv) / len(adv))
            for n in t["name"].names:
                s = n.toUnicode()
                if n.nameID == 6:
                    n.string = s.replace("SFProText", "SFProTextDolphin")
                elif "SF Pro Text" in s:
                    n.string = s.replace("SF Pro Text", "${viewFontFamily}")
            t.save(os.path.join(sys.argv[2], os.path.basename(f).replace("SF-Pro-Text", "SF-Pro-Text-Dolphin")))
        EOF
      '';

  # Read-only defaults layered under ~/.config via XDG_CONFIG_DIRS, so Dolphin can still write its
  # own settings there.
  kdeDefaults = pkgs.runCommand "dolphin-defaults" { } ''
    mkdir $out
    cp ${catppuccinKde}/share/color-schemes/CatppuccinMochaMauve.colors $out/kdeglobals
    chmod +w $out/kdeglobals
    sed -i '/^\[General\]$/a\
    font=SF Pro Text,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\
    menuFont=SF Pro Text,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\
    toolBarFont=SF Pro Text,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\
    smallestReadableFont=SF Pro Text,8,-1,5,400,0,0,0,0,0,0,0,0,0,0,1\
    fixed=FiraCode Nerd Font,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1' $out/kdeglobals
    printf '\n[Icons]\nTheme=${iconTheme}\n' >> $out/kdeglobals
    cat > $out/dolphinrc <<EOF
    [IconsMode]
    IconSize=48
    PreviewSize=48
    UseSystemFont=false
    ViewFont=${viewFontFamily},10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1
    EOF
  '';

  # Places panel and the dock separator paint nothing themselves, so they'd show the window glass.
  styleSheet = pkgs.writeText "dolphin.qss" ''
    PlacesPanel { background-color: #181825; }
    QMainWindow::separator { background-color: #181825; }
  '';

  qtPlugins = lib.makeSearchPath kp.qtbase.qtPluginPrefix [
    kp.plasma-integration
    kp.qtstyleplugin-kvantum
    kp.kio-extras
    kp.ffmpegthumbs
    kp.kdegraphics-thumbnailers
    kp.qtimageformats
    kp.qtsvg
  ];

  # Theme is passed as Qt flags rather than QT_* env vars so apps opened from Dolphin don't inherit it.
  dolphin = pkgs.symlinkJoin {
    name = "dolphin-themed";
    paths = [ kp.dolphin ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/dolphin \
        --prefix QT_PLUGIN_PATH : ${qtPlugins} \
        --prefix XDG_CONFIG_DIRS : ${kdeDefaults} \
        --add-flags "-platformtheme kde -style kvantum -stylesheet ${styleSheet}"

      service=share/dbus-1/services/org.kde.dolphin.FileManager1.service
      rm $out/$service
      substitute ${kp.dolphin}/$service $out/$service \
        --replace-fail ${kp.dolphin}/bin/dolphin $out/bin/dolphin
    '';
  };
in
{
  home.packages = [
    dolphin
    kp.breeze-icons
    papirus
    icons
  ];

  xdg.dataFile."fonts/sf-pro-text-dolphin".source = viewFont;

  xdg.configFile = {
    "Kvantum/${kvantumTheme}".source = glassTheme;
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
