{
  buildNpmPackage,
  lib,
}:
buildNpmPackage {
  pname = "discord-context";
  version = "0.1.0";
  src = lib.cleanSource ./.;
  npmDepsHash = "sha256-WKlpJbo40C7QvWGAm+LrLFSbtro4I1zqKZjH6VbOpA8=";
  dontNpmBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm test
    runHook postCheck
  '';
  meta = {
    description = "Read-only Discord search MCP with server and channel exclusions";
    mainProgram = "discord-context";
    platforms = lib.platforms.linux;
  };
}
