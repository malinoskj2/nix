{
  catppuccin-papirus-folders,
  lib,
  name,
  palette,
  runCommand,
}:

let
  papirus = catppuccin-papirus-folders.override {
    flavor = "mocha";
    accent = "blue";
  };
  source = "${papirus}/share/icons/Papirus-Dark";
  # Renamed so it can't shadow the Papirus-Dark that other apps load.
  parent = "${name}-Papirus-Dark";

  # Papirus draws 16px places as monochrome glyphs, so the chooser's list and sidebar get the
  # filled 22px and 32px folders drawn at 16px instead.
  folders = {
    folder = "blue";
    inode-directory = "blue";
    user-home = "mauve";
    user-desktop = "lavender";
    folder-documents = "blue";
    folder-download = "green";
    folder-music = "sapphire";
    folder-pictures = "pink";
    folder-publicshare = "flamingo";
    folder-templates = "peach";
    folder-videos = "red";
    document-open-recent = "rosewater";
    starred = "yellow";
  };
  trash = [
    "user-trash"
    "user-trash-full"
  ];
  sizes = {
    "16x16/places" = "22x22";
    "16x16@2x/places" = "32x32";
  };

  linkFolders =
    dir: size:
    lib.concatLines (
      lib.mapAttrsToList (
        icon: accent:
        "ln -s ${source}/${size}/places/folder-cat-mocha-${accent}.svg $theme/${dir}/${icon}.svg"
      ) folders
    );
  greyTrash =
    dir: size:
    lib.concatMapStrings (icon: ''
      sed -e 's/#89B4FA/#${palette.overlay1}/I' -e 's/#75A0E6/#${palette.overlay0}/I' \
        ${source}/${size}/places/folder-cat-mocha-blue.svg > $theme/${dir}/${icon}.svg
    '') trash;
in
runCommand name { } ''
  mkdir -p $out/share/icons/${parent}
  for entry in ${source}/*; do
    [ "''${entry##*/}" = index.theme ] || ln -s "$entry" $out/share/icons/${parent}/
  done
  sed 's/^Name=.*/Name=${parent}/' ${source}/index.theme > $out/share/icons/${parent}/index.theme

  theme=$out/share/icons/${name}
  ${lib.concatLines (
    lib.mapAttrsToList (dir: size: ''
      mkdir -p $theme/${dir}
      ${linkFolders dir size}
      ${greyTrash dir size}
    '') sizes
  )}
  cat > $theme/index.theme <<EOF
  [Icon Theme]
  Name=${name}
  Inherits=${parent},hicolor
  Directories=16x16/places,16x16@2x/places

  [16x16/places]
  Size=16
  Context=Places
  Type=Fixed

  [16x16@2x/places]
  Size=16
  Scale=2
  Context=Places
  Type=Fixed
  EOF
''
