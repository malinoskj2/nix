# Catppuccin Mocha Mauve with the top bar turned into the same crust glass as the Firefox toolbox,
# Zed title bar and hyprbars. Kvantum paints a window with its "Window" element only when a toolbar
# sits at the window's top-left pixel, otherwise with "Dialog". So the toolbar keeps an invisible
# frame (dropping it puts a button there and the main window resolves to Dialog), Window carries the
# glass alpha in the SVG, and Dialog gets an opaque element so dialogs stay solid.
# reduce_window_opacity must be nonzero or Kvantum skips translucency, but it dims every element,
# dialogs included, so it stays at 1% and the real alpha lives in the SVG.
{
  lib,
  runCommand,
  python3,
  catppuccin-kvantum,
  palette,
  name,
}:

runCommand name { nativeBuildInputs = [ python3 ]; } ''
  mkdir $out
  python3 ${./kvantum-glass.py} \
    ${catppuccin-kvantum}/share/Kvantum/catppuccin-mocha-mauve/catppuccin-mocha-mauve \
    $out/${name} \
    ${lib.toUpper palette.mocha.base} ${lib.toUpper palette.mocha.crust} ${palette.opacity palette.glass.chrome}
''
