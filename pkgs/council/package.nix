{
  lib,
  python3,
  runCommand,
  writeShellApplication,
}:
let
  source = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "py") ./.;
  };
in
(writeShellApplication {
  name = "council";
  runtimeInputs = [ python3 ];
  text = ''
    exec ${lib.getExe python3} ${source}/council.py "$@"
  '';
}).overrideAttrs
  {
    passthru.tests.council =
      runCommand "council-tests"
        {
          nativeBuildInputs = [ python3 ];
        }
        ''
          cp ${source}/*.py .
          python -m unittest -v test_council
          touch "$out"
        '';
    meta.description = "Ask Codex, Claude and Gemini the same review or question in parallel";
  }
