{
  autoPatchelfHook,
  buildNpmPackage,
  fetchurl,
  jq,
  lib,
  libxcb,
  ncurses,
  stdenv,
}:

buildNpmPackage (finalAttrs: {
  pname = "deepsec";
  version = "2.3.12";

  src = fetchurl {
    url = "https://registry.npmjs.org/deepsec/-/deepsec-${finalAttrs.version}.tgz";
    hash = "sha256-ZGS2E5C4+8xORFqMb6LWIc2V5PLpoy8NRM3rTcQiZ7o=";
  };

  # The published bundle includes its build output, but retains workspace-only dev dependencies.
  postPatch = ''
    ${lib.getExe jq} 'del(.devDependencies)' package.json > package.json.tmp
    mv package.json.tmp package.json
    cp ${./package-lock.json} package-lock.json
  '';

  npmDepsFetcherVersion = 2;
  npmDepsHash = "sha256-iF4CSRs1j34m/kEOlvEXOIk0fl7jw27IEcm+UCEAKcQ=";

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    libxcb
    ncurses
    stdenv.cc.cc.lib
  ];

  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;

  meta = {
    description = "Vercel's agent-powered vulnerability scanner";
    homepage = "https://github.com/vercel-labs/deepsec";
    license = lib.licenses.asl20;
    mainProgram = "deepsec";
    platforms = lib.platforms.linux;
  };
})
