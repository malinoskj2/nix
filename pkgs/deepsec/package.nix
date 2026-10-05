{
  autoPatchelfHook,
  buildNpmPackage,
  fetchurl,
  jq,
  lib,
  ncurses,
  stdenv,
}:

buildNpmPackage (finalAttrs: {
  pname = "deepsec";
  version = "2.3.10";

  src = fetchurl {
    url = "https://registry.npmjs.org/deepsec/-/deepsec-${finalAttrs.version}.tgz";
    hash = "sha256-D1h7Q+azOEOEcW/6vxSitFbYvHFYvw5r8iv3K0NeFGE=";
  };

  # The published bundle includes its build output, but retains workspace-only dev dependencies.
  postPatch = ''
    ${lib.getExe jq} 'del(.devDependencies)' package.json > package.json.tmp
    mv package.json.tmp package.json
    cp ${./package-lock.json} package-lock.json
  '';

  npmDepsFetcherVersion = 2;
  npmDepsHash = "sha256-PXuzNaU0QJbONaSWWMxTEkgxRAQU6uBsUXGkH34AhS4=";
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    ncurses
    stdenv.cc.cc.lib
  ];

  meta = {
    description = "Vercel's agent-powered vulnerability scanner";
    homepage = "https://github.com/vercel-labs/deepsec";
    license = lib.licenses.asl20;
    mainProgram = "deepsec";
    platforms = lib.platforms.linux;
  };
})
