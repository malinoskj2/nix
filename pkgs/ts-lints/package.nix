{
  buildNpmPackage,
  lib,
  makeWrapper,
  nodejs_24,
}:
buildNpmPackage {
  pname = "ts-lints";
  version = "1";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./bin
      ./config.mjs
      ./package-lock.json
      ./package.json
      ./plugin
      ./tests
      ./tsconfig.strict.json
    ];
  };
  nodejs = nodejs_24;
  npmDepsHash = "sha256-ItSLy/MCSkSmwvgWNPukfH6qDQ3PG4HmNc//mqJTTz0=";
  dontNpmBuild = true;
  nativeBuildInputs = [ makeWrapper ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm test
    runHook postCheck
  '';
  postInstall = ''
    wrapProgram $out/bin/ts-lints --set-default NODE_OPTIONS --max-old-space-size=8192
  '';
  meta = {
    description = "Jesse's shared TypeScript and Vue lint set and a runner for any project";
    mainProgram = "ts-lints";
    platforms = lib.platforms.linux;
  };
}
