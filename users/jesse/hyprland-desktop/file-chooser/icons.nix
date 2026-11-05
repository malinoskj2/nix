{
  catppuccin-papirus-folders,
  lib,
  mocha,
  name,
  runCommand,
  writeText,
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

  places =
    dir: size:
    let
      folder = accent: "${source}/${size}/places/folder-cat-mocha-${accent}.svg";
    in
    [ "mkdir -p $theme/${dir}" ]
    ++ lib.mapAttrsToList (icon: accent: "ln -s ${folder accent} $theme/${dir}/${icon}.svg") folders
    # The trash is the blue folder with its two shades turned gray.
    ++ map (
      icon:
      "sed -e 's/#89B4FA/#${mocha.overlay1}/I' -e 's/#75A0E6/#${mocha.overlay0}/I' ${folder "blue"} > $theme/${dir}/${icon}.svg"
    ) trash;

  index = writeText "index.theme" ''
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
  '';
in
runCommand name { } ''
  mkdir -p $out/share/icons/${parent}
  ln -s ${source}/* $out/share/icons/${parent}/
  rm $out/share/icons/${parent}/index.theme
  sed 's/^Name=.*/Name=${parent}/' ${source}/index.theme > $out/share/icons/${parent}/index.theme

  theme=$out/share/icons/${name}
  ${lib.concatLines (lib.concatLists (lib.mapAttrsToList places sizes))}
  cp ${index} $theme/index.theme
''
