{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  dpkg,
  runCommand,
  makeDesktopItem,
  copyDesktopItems,
  autoPatchelfHook,
  makeBinaryWrapper,
  glib,
  gsettings-desktop-schemas,
  gtk3,
  python3,
  wayland,
  unstable,
  appearanceSettings ? { },
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
  pnpm = pnpm_11.override { nodejs-slim = nodejs_24; };
  vscode-nix-ide = fetchFromGitHub {
    owner = "nix-community";
    repo = "vscode-nix-ide";
    rev = "065fcba88075f682cdd4db7738f13d2c9e2d5c6a";
    hash = "sha256-GLVWBO0JrsK4dxZ7F2xeXltAFgBV4bkfiPQcb7EuFHU=";
  };
  sourceCommit = "a0cd1644f320f1327f7495650a816111b495f3cd";
  arch = stdenv.hostPlatform.node.arch;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "orca-ade";
  version = "1.4.229";

  src = fetchFromGitHub {
    owner = "stablyai";
    repo = "orca";
    tag = "v${finalAttrs.version}";
    hash = "sha256-iaid1L+v0ME7IPB4oDxyUe7CtpOOL6cMQjQHpqtIdEI=";
  };

  patches = [
    ./catppuccin.patch
    ./glass-titlebar.patch
    ./claude-hooks.patch
    ./open-video-externally.patch
    ./nix-syntax.patch
    ./clipboard-shared-media.patch
  ];

  # The glibc floor guards Ubuntu 20.04 users of the upstream AppImage.
  postPatch = ''
    # Apply declarative appearance to new and existing profiles at startup,
    # without replacing Orca's mutable workspace/session state.
    cat > src/shared/nix-appearance-settings.ts <<'EOF'
    import type { GlobalSettings } from './global-settings-types'
    export const nixAppearanceSettings = ${builtins.toJSON appearanceSettings} satisfies Partial<GlobalSettings>
    EOF
    sed -i "1i import { nixAppearanceSettings } from './nix-appearance-settings'" \
      src/shared/default-global-settings.ts
    # Keep the declarative overrides after the defaults without TS2783's duplicate-key error
    # for overrides also named explicitly in the defaults object.
    sed -i 's/^  return {$/  return Object.assign<GlobalSettings, Partial<GlobalSettings>>({/; s/^  }$/  }, nixAppearanceSettings)/' \
      src/shared/default-global-settings.ts
    sed -i "1i import { nixAppearanceSettings } from '../../../shared/nix-appearance-settings'" \
      src/main/persistence/loading-store/normalize-loaded-global-settings.ts
    substituteInPlace src/main/persistence/loading-store/normalize-loaded-global-settings.ts \
      --replace-fail '...stripRetiredGlobalSettings(parsed.settings),' \
        '...stripRetiredGlobalSettings(parsed.settings), ...nixAppearanceSettings,'
    # Official skill installs pin to the tag's commit, which upstream reads from a git checkout.
    substituteInPlace config/scripts/build-source-commit.mjs \
      --replace-fail "execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()" "'${sourceCommit}'"
    substituteInPlace config/electron-builder.config.cjs \
      --replace-fail "const { verifyLinuxGlibcFloor } = require('./scripts/verify-linux-glibc-floor.cjs')" \
        "const verifyLinuxGlibcFloor = () => {}"
    # Only the AppImage ships the downloaded Node; the deb and rpm drop it again.
    substituteInPlace config/electron-builder.config.cjs \
      --replace-fail "appImageNodeRuntime = await placeAppImageNodeRuntime(resourcesDir, targetArch)" ""
    # Upstream builds the Wayland clipboard helper in Docker; buildPhase compiles it instead.
    substituteInPlace config/wayland-clipboard-resources.cjs \
      --replace-fail "[join(root, 'config', 'scripts', 'build-wayland-clipboard.mjs'), '--arch', arch]" "['-e', \"\"]"
    substituteInPlace src/shared/default-global-settings.ts \
      --replace-fail "keepComputerAwakeWhileAgentsRun: false," "keepComputerAwakeWhileAgentsRun: true,"
    # Uploaded bundles come from the read-only store, and Orca writes into them after extracting.
    substituteInPlace src/main/ssh/system-ssh-file-transfer.ts \
      --replace-fail 'tar -xzf - -C ''${shellEscape(remoteDir)}`' \
        'tar -xzf - -C ''${shellEscape(remoteDir)} && chmod -R u+w ''${shellEscape(remoteDir)}`'
    grammars=src/renderer/src/lib/monaco-languages/textmate-grammars
    cp ${vscode-nix-ide}/dist/nix.tmLanguage.json $grammars/nix.tmLanguage.json
    cp ${vscode-nix-ide}/LICENSE $grammars/nix-LICENSE.txt
  '';

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    hash = "sha256-0dIkyKpNvTvp0p2LTWLD85qWYeis0I1ttNMwF3J6zS4=";
  };

  mobilePnpmDeps = fetchPnpmDeps {
    pname = "${finalAttrs.pname}-mobile";
    inherit (finalAttrs) version src;
    inherit pnpm;
    sourceRoot = "${finalAttrs.src.name}/mobile";
    fetcherVersion = 4;
    hash = "sha256-6xqV7XBncnUoMOH2wU3eleC5YIqXgh5dnCrJRVodwAE=";
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

  buildInputs = [
    (lib.getLib stdenv.cc.cc)
    wayland
  ];

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

    pnpm run build:packages
    pnpm exec tsc -p config/tsconfig.build.cli.json --outDir out --composite false --incremental false
    node config/scripts/verify-cli-bin.mjs --fix-executable --fix-package-json
    pnpm run build:electron-vite
    pnpm run verify:built-skills-cli
    pnpm run build:web-from-renderer
    pnpm run build:mobile-web

    mkdir -p native/wayland-clipboard/.build/${arch}
    $CC -O2 -Wall -Wextra native/wayland-clipboard/wayland-clipboard.c \
      native/wayland-clipboard/x11-clipboard-publisher.c -ldl \
      -o native/wayland-clipboard/.build/${arch}/orca-wayland-clipboard

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
      ! -name 'agent-browser-linux-${arch}' -delete
    ln -s ${finalAttrs.passthru.orcadTemplate} $out/libexec/orca-ade/resources/orcad-template
    install -Dm444 resources/icon.png $out/share/icons/hicolor/512x512/apps/orca-ade.png
    mkdir -p $out/share/orca-ade
    cp -r skills $out/share/orca-ade/skills

    wrapProgram $out/libexec/orca-ade/orca-ide \
      --prefix XDG_DATA_DIRS : ${glib.getSchemaDataDirPath gsettings-desktop-schemas}:${glib.getSchemaDataDirPath gtk3} \
      --set CHROME_DEVEL_SANDBOX ${electron}/libexec/electron/chrome-sandbox
    ln -s $out/libexec/orca-ade/resources/bin/orca-ide $out/bin/orca-ide
    # The skills call bare `orca`, which upstream reserves on Linux for the GNOME screen reader.
    ln -s $out/libexec/orca-ade/resources/bin/orca-ide $out/bin/orca
    ln -s $out/libexec/orca-ade/orca-ide $out/bin/orca-ade

    runHook postInstall
  '';

  postFixup = ''
    autoPatchelf $out/libexec/orca-ade/resources
    # The clipboard helper dlopens these by soname.
    patchelf --add-rpath ${
      lib.makeLibraryPath [
        wayland
        gtk3
      ]
    } $out/libexec/orca-ade/resources/bin/orca-wayland-clipboard
  '';

  # SSH and WSL hosts run orcad from this template. Its prebuilt addons cover every remote
  # target, which only upstream's release pipeline builds, and its manifest pins their hashes.
  passthru.orcadTemplate =
    runCommand "orca-ade-orcad-template-${finalAttrs.version}"
      {
        src = fetchurl {
          url = "https://github.com/stablyai/orca/releases/download/v${finalAttrs.version}/orca-ide_${finalAttrs.version}_amd64.deb";
          hash = "sha256-7TNqh4iWW1mHkIITcPUOC40C8sqJrdOGZt8F6A5jKOQ=";
        };
        nativeBuildInputs = [ dpkg ];
      }
      ''
        dpkg --fsys-tarfile $src | tar --extract ./opt/Orca/resources/orcad-template
        mv opt/Orca/resources/orcad-template $out
      '';

  desktopItems = [
    (makeDesktopItem {
      name = "orca-ade";
      desktopName = "Orca";
      comment = finalAttrs.meta.description;
      exec = "orca-ade %U";
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
