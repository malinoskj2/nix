{
  lib,
  stdenv,
  fetchFromGitHub,
  makeDesktopItem,
  copyDesktopItems,
  autoPatchelfHook,
  makeBinaryWrapper,
  glib,
  gsettings-desktop-schemas,
  gtk3,
  python3,
  unstable,
}:

let
  inherit (unstable)
    electron_43
    fetchPnpmDeps
    nodejs_24
    pnpmConfigHook
    pnpm_11
    ;
  electron = electron_43;
  pnpm = pnpm_11.override { nodejs = nodejs_24; };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "orca-ade";
  version = "1.4.212";

  src = fetchFromGitHub {
    owner = "stablyai";
    repo = "orca";
    tag = "v${finalAttrs.version}";
    hash = "sha256-gUj0REuVXpAB1DnxllrIFrTqI54geC8XkZAmwItTtzc=";
  };

  patches = [ ./claude-hooks.patch ];

  # The glibc floor guards Ubuntu 20.04 users of the upstream AppImage.
  postPatch = ''
    substituteInPlace config/electron-builder.config.cjs \
      --replace-fail "const { verifyLinuxGlibcFloor } = require('./scripts/verify-linux-glibc-floor.cjs')" \
        "const verifyLinuxGlibcFloor = () => {}"
  '';

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    hash = "sha256-3n2ZdT+NxA6Ht1AvDnqAYMwFzS1Z+USWpvBP9sfOJcw=";
  };

  mobilePnpmDeps = fetchPnpmDeps {
    pname = "${finalAttrs.pname}-mobile";
    inherit (finalAttrs) version src;
    inherit pnpm;
    sourceRoot = "${finalAttrs.src.name}/mobile";
    fetcherVersion = 4;
    hash = "sha256-fSC+EpPI00AnulrQcPurEGU6bwSXhc2wrX+Kg94BZPg=";
  };

  postConfigure = ''
    pnpmDeps=$mobilePnpmDeps pnpmRoot=mobile pnpmConfigHook
    (cd mobile && pnpm run postinstall)
  '';

  nativeBuildInputs = [
    autoPatchelfHook
    copyDesktopItems
    makeBinaryWrapper
    nodejs_24
    pnpm
    pnpmConfigHook
    python3
  ];

  buildInputs = [ (lib.getLib stdenv.cc.cc) ];

  # Electron dlopens libGL, Vulkan, PipeWire and libsecret through its rpath.
  dontPatchELF = true;
  dontAutoPatchelf = true;

  env = {
    ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
    npm_config_manage_package_manager_versions = "false";
    pnpm_config_verify_deps_before_run = "false";
  };

  buildPhase = ''
    runHook preBuild

    export npm_config_nodedir=${electron.headers}
    pnpm rebuild node-pty @parcel/watcher

    pnpm run build:relay
    pnpm exec tsc -p config/tsconfig.cli.json --outDir out --composite false --incremental false
    node config/scripts/verify-cli-bin.mjs --fix-executable --fix-package-json
    pnpm run build:electron-vite
    pnpm run verify:built-skills-cli
    pnpm run build:web-from-renderer
    pnpm run build:mobile-web

    cp -r ${electron.dist} electron-dist
    chmod -R u+w electron-dist
    pnpm exec electron-builder --config config/electron-builder.config.cjs \
      --linux dir \
      -c.electronDist=electron-dist \
      -c.electronVersion=${electron.version} \
      -c.npmRebuild=false

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec $out/bin
    cp -r dist/linux-unpacked $out/libexec/orca-ade
    find $out/libexec/orca-ade/resources -type d -path '*/node-pty/prebuilds' -prune -exec rm -r {} +
    find $out/libexec/orca-ade/resources -path '*/agent-browser/bin/agent-browser-*' \
      ! -name 'agent-browser-linux-${stdenv.hostPlatform.node.arch}' -delete
    install -Dm444 resources/icon.png $out/share/icons/hicolor/512x512/apps/orca-ade.png

    wrapProgram $out/libexec/orca-ade/orca-ide \
      --prefix XDG_DATA_DIRS : ${glib.getSchemaDataDirPath gsettings-desktop-schemas}:${glib.getSchemaDataDirPath gtk3} \
      --set CHROME_DEVEL_SANDBOX ${electron}/libexec/electron/chrome-sandbox
    ln -s $out/libexec/orca-ade/resources/bin/orca-ide $out/bin/orca-ide

    runHook postInstall
  '';

  postFixup = ''
    autoPatchelf $out/libexec/orca-ade/resources
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "orca-ade";
      desktopName = "Orca";
      comment = finalAttrs.meta.description;
      exec = "${placeholder "out"}/libexec/orca-ade/orca-ide %U";
      icon = "orca-ade";
      startupWMClass = "orca";
      mimeTypes = [ "x-scheme-handler/orca" ];
      categories = [ "Development" ];
    })
  ];

  meta = {
    description = "IDE for running coding agents in parallel";
    homepage = "https://github.com/stablyai/orca";
    license = lib.licenses.mit;
    mainProgram = "orca-ide";
    platforms = lib.platforms.linux;
  };
})
