{
  lib,
  palette,
  python3,
  runCommand,
}:

let
  # How far, in percent, the page's white moves toward the bar's crust.
  dim = 8;
in
runCommand "claude-desktop-light" { nativeBuildInputs = [ python3 ]; } ''
  python3 ${./light/dim.py} \
    ${lib.escapeShellArg (palette.withAlpha palette.mocha.crust palette.glass.chrome)} \
    ${palette.mocha.crust} \
    ${toString dim} \
    $out
  cp ${./light/claude.js} $out/claude.js
  # The symbol color the app uses in dark mode.
  printf '#c2c0b6' > $out/title-bar-symbol-light
''
