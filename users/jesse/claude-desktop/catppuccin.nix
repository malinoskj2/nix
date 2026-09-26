{
  lib,
  palette,
  python3,
  runCommand,
}:

runCommand "claude-desktop-catppuccin" { nativeBuildInputs = [ python3 ]; } ''
  python3 ${./catppuccin.py} \
    ${lib.escapeShellArg (builtins.toJSON palette.mocha)} \
    ${lib.escapeShellArg (palette.withAlpha palette.mocha.crust palette.glass.chrome)} \
    $out
  printf catppuccin-mocha > $out/code-theme-dark
''
