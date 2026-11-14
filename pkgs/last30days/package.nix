{
  fetchFromGitHub,
  ffmpeg,
  lib,
  makeWrapper,
  nodejs,
  python3,
  runCommand,
  stdenvNoCC,
  yt-dlp,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "last30days";
  version = "3.39.0";

  src = fetchFromGitHub {
    owner = "mvanhorn";
    repo = "last30days-skill";
    rev = "f0876504bdfcada40fcf5a4a3ada014c9408b9ed";
    hash = "sha256-PdIYPWn5tXJJH+n33uxxA5ecpYGKp8xZBjnKmUJlkXU=";
  };

  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/last30days" "$out/bin"
    cp -r skills pyproject.toml LICENSE "$out/share/last30days/"
    makeWrapper ${lib.getExe python3} "$out/bin/last30days" \
      --add-flags "$out/share/last30days/skills/last30days/scripts/last30days.py" \
      --prefix PATH : ${
        lib.makeBinPath [
          yt-dlp
          ffmpeg
          nodejs
        ]
      } \
      --set PYTHONDONTWRITEBYTECODE 1
    runHook postInstall
  '';

  passthru.tests.search =
    runCommand "last30days-search-test" { nativeBuildInputs = [ finalAttrs.finalPackage ]; }
      ''
        export HOME="$TMPDIR" LAST30DAYS_CONFIG_DIR="" LAST30DAYS_SKIP_KEYCHAIN=1
        last30days --help >/dev/null
        for source in youtube tiktok; do
          ${lib.getExe python3} -c '
        import json, sys
        json.dump({
            "intent": "concept", "freshness_mode": "strict_recent", "cluster_mode": "none",
            "subqueries": [{"search_query": "NixOS", "ranking_query": "NixOS videos", "sources": [sys.argv[1]]}]
        }, sys.stdout)
        ' "$source" >plan.json
          last30days --research-only --mock --search "$source" --emit json \
            --no-browser-cookies --plan plan.json --save-dir "$TMPDIR/$source" "NixOS" >report.json
          ${lib.getExe python3} -c '
        import json, sys
        report = json.load(open("report.json"))
        assert sys.argv[1] in report["source_status"], report
        ' "$source"
        done
        touch "$out"
      '';

  meta = {
    description = "Pinned last30days social research engine";
    homepage = "https://github.com/mvanhorn/last30days-skill";
    license = lib.licenses.mit;
    mainProgram = "last30days";
    platforms = lib.platforms.linux;
  };
})
