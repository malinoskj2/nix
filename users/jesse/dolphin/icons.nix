{
  name,
  palette,
  papirus,
  python3,
  runCommand,
  writeText,
}:

let
  colors = writeText "catppuccin-palette.json" (builtins.toJSON { inherit (palette) latte mocha; });
in
runCommand name { nativeBuildInputs = [ python3 ]; } ''
  mkdir -p $out/share/icons/${name}
  python3 ${./papirus-catppuccin.py} ${papirus}/share/icons/Papirus-Dark $out/share/icons/${name} ${name} ${colors}
''
