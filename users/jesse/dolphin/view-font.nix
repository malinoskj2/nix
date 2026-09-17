# SF Pro declares an average glyph width of 1.18em (the real one is ~0.56em), and Dolphin sizes
# icon-view cells from it, so they come out twice as wide as the names need. This copy carries the
# real metric under its own family name and is used for the view font only.
{
  runCommand,
  python3,
  sf-pro,
  family,
}:

runCommand "sf-pro-text-dolphin"
  { nativeBuildInputs = [ (python3.withPackages (p: [ p.fonttools ])) ]; }
  ''
    mkdir $out
    python3 ${./sf-pro-text-dolphin.py} ${sf-pro}/share/fonts/opentype $out "${family}"
  ''
