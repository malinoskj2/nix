{
  runCommand,
  python3,
  writeText,
  papirus,
  palette,
  name,
}:

let
  colors = writeText "catppuccin-palette.json" (builtins.toJSON { inherit (palette) mocha latte; });
in

runCommand name { nativeBuildInputs = [ python3 ]; } ''
  mkdir -p $out/share/icons/${name}
  python3 ${./papirus-catppuccin.py} ${papirus}/share/icons/Papirus-Dark $out/share/icons/${name} ${name} ${colors}
''
