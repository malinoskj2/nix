{
  fetchFromGitHub,
  fetchPnpmDeps,
  makeWrapper,
  nodejs,
  pnpm_11,
  pnpmConfigHook,
  stdenv,
}:

let
  # pnpm no longer reads overrides and patchedDependencies from package.json, but its
  # frozen-lockfile check still compares them against the lockfile, so they move to
  # pnpm-workspace.yaml for the install to proceed and the patches to apply.
  pnpmFieldPatch = ''
    cat >> pnpm-workspace.yaml <<'EOF'
    overrides:
      react: 19.2.7
      react-dom: 19.2.7
    patchedDependencies:
      "@arms/rum-electron@0.0.3": patches/@arms__rum-electron@0.0.3.patch
      "@ai-sdk/openai-compatible@2.0.60": patches/@ai-sdk__openai-compatible@2.0.60.patch
      "@ai-sdk/anthropic@3.0.81": patches/@ai-sdk__anthropic@3.0.81.patch
    EOF
  '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "zcode";
  version = "3.14.3";
  rev = "29628c9acdb81b703bbd4080c207a0e7ce5e276e";

  src = fetchFromGitHub {
    owner = "zai-org";
    repo = "ZCode";
    inherit (finalAttrs) rev;
    hash = "sha256-4LZIl6ofaxcmb28fu21Kc5oJAe+/AKRDAM/2xRKYxI8=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname src;
    pnpm = pnpm_11;
    fetcherVersion = 4;
    hash = "sha256-L4iFXLHLmJd76wx7YX5T3O59ffI+2eodDHe39PGfTgc=";
    postPatch = pnpmFieldPatch;
  };

  nativeBuildInputs = [
    makeWrapper
    nodejs
    pnpm_11
    pnpmConfigHook
  ];

  postPatch = pnpmFieldPatch;

  buildPhase = ''
    runHook preBuild
    pnpm exec tsc -b packages/shared
    pnpm --filter @zcode/cli... run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    export ZCODE_SOURCE_ROOT=$PWD
    export ZCODE_DIST_ROOT=$out/lib
    export ZCODE_SEA_TUI_ASSETS=$PWD/apps/zcode-cli/packages/cli/scripts/sea-tui-assets.mjs
    export ZCODE_TARGET=${
      {
        x86_64-linux = "linux-x64";
        aarch64-linux = "linux-arm64";
        x86_64-darwin = "darwin-x64";
        aarch64-darwin = "darwin-arm64";
      }
      .${stdenv.hostPlatform.system} or (throw "zcode: unsupported system ${stdenv.hostPlatform.system}")
    }
    export ZCODE_VERSION=${finalAttrs.version}
    node ${./stage-terminal-dist.mjs}
    mkdir -p $out/bin
    makeWrapper ${nodejs}/bin/node $out/bin/zcode \
      --add-flags $out/lib/zcode/bin/zcode.mjs
    runHook postInstall
  '';

  meta = {
    description = "Z.ai's ZCode terminal agent harness (official CLI and TUI), built from source";
    mainProgram = "zcode";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
})
