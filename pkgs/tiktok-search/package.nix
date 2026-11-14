{
  chromium,
  lib,
  python3,
  runCommand,
  writeShellApplication,
}:
let
  python = python3.withPackages (ps: [ ps.playwright ]);
  package = writeShellApplication {
    name = "tiktok-search";
    runtimeInputs = [ chromium ];
    text = ''
      export PYTHONDONTWRITEBYTECODE=1
      exec ${lib.getExe python} ${./search.py} "$@"
    '';
    meta.description = "Bounded browser-based TikTok video discovery with date and engagement filters";
  };
in
package.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    tests.search = runCommand "tiktok-search-test" { } ''
      cp ${./search.py} search.py
      cp ${./test_search.py} test_search.py
      ${lib.getExe python3} -m unittest -v
      touch "$out"
    '';
  };
})
