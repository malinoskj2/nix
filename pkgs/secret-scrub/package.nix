{
  lib,
  python3,
  runCommand,
  writeShellScriptBin,
}:
(writeShellScriptBin "secret-scrub" ''
  exec ${lib.getExe python3} -I ${./secret_scrub.py} "$@"
'').overrideAttrs
  {
    passthru.tests.scrub =
      runCommand "secret-scrub-tests"
        {
          nativeBuildInputs = [ python3 ];
        }
        ''
          cp ${./secret_scrub.py} secret_scrub.py
          cp ${./test_secret_scrub.py} test_secret_scrub.py
          python -I test_secret_scrub.py -v
          touch "$out"
        '';
    meta = {
      description = "Find, redact or purge leaked tokens in agent transcripts and Orca state without printing them";
      platforms = lib.platforms.linux;
      mainProgram = "secret-scrub";
    };
  }
