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
  globalSettings ? { },
  approvedPlugins ? [ ],
  discordPresenceSettings ? { },
  # Command that automatic Claude, Codex and Muse resumes in local workspaces run through, as
  # `<command> <agent> ...`.
  agentResumeWrapper ? null,
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
  discord-presence = fetchFromGitHub {
    owner = "jondmarien";
    repo = "orca-discord-presence";
    rev = "cd0630bbcc2c830765a51fc023fe736dfe7f0f06";
    hash = "sha256-z7r3qtsJxwz0AcHXNY811Irz2mzBGLpFZcjc9vSfaJ8=";
  };
  sourceCommit = "27eb5e2a6c5017c6fdcba4fee16bf54256550c6f";
  arch = stdenv.hostPlatform.node.arch;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "orca-ade";
  version = "1.4.253";

  src = fetchFromGitHub {
    owner = "stablyai";
    repo = "orca";
    tag = "v${finalAttrs.version}";
    hash = "sha256-kqm3C8ErQ3i3gR7gqizlm6qparI3PIADgmP9T2DANoo=";
  };

  patches = [
    ./catppuccin.patch
    ./glass-titlebar.patch
    ./claude-hooks.patch
    ./open-video-externally.patch
    ./nix-syntax.patch
    ./clipboard-shared-media.patch
    ./bundled-plugins.patch
    ./approved-plugins.patch
    ./agent-resume-wrapper.patch
  ];

  postPatch = ''
    # Apply declarative settings to new and existing profiles at startup,
    # without replacing Orca's mutable workspace/session state.
    cat > src/shared/nix-global-settings.ts <<'EOF'
    import type { GlobalSettings } from './global-settings-types'
    export const nixGlobalSettings = ${builtins.toJSON globalSettings} satisfies Partial<GlobalSettings>
    EOF
    cat > src/shared/nix-agent-resume-wrapper.ts <<'EOF'
    export const nixAgentResumeWrapper: string | null = ${builtins.toJSON agentResumeWrapper}
    EOF
    # Keep the declarative overrides after the defaults without TS2783's duplicate-key error
    # for overrides also named explicitly in the defaults object.
    sed -i \
      -e "1i import { nixGlobalSettings } from './nix-global-settings'" \
      -e 's/^  return {$/  return Object.assign<GlobalSettings, Partial<GlobalSettings>>({/' \
      -e 's/^  }$/  }, nixGlobalSettings)/' \
      src/shared/default-global-settings.ts
    # Loading re-normalizes some saved fields after spreading them, so the overrides wrap the result.
    sed -i "1i import { nixGlobalSettings } from '../../../shared/nix-global-settings'" \
      src/main/persistence/loading-store/normalize-loaded-global-settings.ts
    substituteInPlace src/main/persistence/loading-store/normalize-loaded-global-settings.ts \
      --replace-fail 'export function normalizeLoadedGlobalSettings(' 'function normalizeLoadedGlobalSettingsUpstream('
    cat >> src/main/persistence/loading-store/normalize-loaded-global-settings.ts <<'EOF'
    export function normalizeLoadedGlobalSettings(
      ...args: Parameters<typeof normalizeLoadedGlobalSettingsUpstream>
    ): PersistedState['settings'] {
      return { ...normalizeLoadedGlobalSettingsUpstream(...args), ...nixGlobalSettings }
    }
    EOF

    substituteInPlace src/shared/default-global-settings.ts \
      --replace-fail "keepComputerAwakeWhileAgentsRun: false," "keepComputerAwakeWhileAgentsRun: true,"

    # Declared plugins run without the consent prompt; disabling one still sticks.
    cat > src/shared/plugins/approval/nix-approved-plugins.ts <<'EOF'
    export const nixApprovedPlugins: readonly string[] = ${builtins.toJSON approvedPlugins}
    EOF

    # Bundled, so Orca installs and updates it from the package like its own launch plugins.
    plugin=resources/plugins/launch/chron0.discord-presence
    mkdir $plugin
    cp -r ${discord-presence}/{orca-plugin.json,README.md,dist,panel} $plugin
    chmod -R u+w $plugin
    # Saved settings still win over these defaults. The worker would otherwise rewrite its panel
    # inside the hash-addressed install, which Orca then rejects as corrupted.
    substituteInPlace $plugin/dist/main.js \
      --replace-fail 'var BOOLEAN_FIELDS = ' ${lib.escapeShellArg "DEFAULT_SETTINGS = Object.freeze({ ...DEFAULT_SETTINGS, ...${builtins.toJSON discordPresenceSettings} }); var BOOLEAN_FIELDS = "} \
      --replace-fail 'normalizeOpenUrl(source.openUrl);' 'normalizeOpenUrl(source.openUrl ?? DEFAULT_SETTINGS.openUrl);' \
      --replace-fail 'normalizeBridgeUrl(source.bridgeUrl);' 'normalizeBridgeUrl(source.bridgeUrl ?? DEFAULT_SETTINGS.bridgeUrl);' \
      --replace-fail 'normalizeBridgeToken(source.bridgeToken);' 'normalizeBridgeToken(source.bridgeToken ?? DEFAULT_SETTINGS.bridgeToken);' \
      --replace-fail 'const skip = env[PANEL_WRITE_SKIP_ENV];' 'const skip = "1";' \
      --replace-fail 'return "Working in Orca";' 'return "Working in Orca ADE";'
    node -e '
      const { readFileSync, writeFileSync } = require("node:fs")
      const { hashPackagedPluginTree } = require("./config/scripts/desktop-distribution/runtime-verification/verify-packaged-plugin-resources.cjs")
      const [indexPath, plugin] = process.argv.slice(1)
      const index = JSON.parse(readFileSync(indexPath, "utf8"))
      index.plugins.push({
        pluginKey: "chron0.discord-presence",
        path: "chron0.discord-presence",
        contentHash: hashPackagedPluginTree(plugin)
      })
      writeFileSync(indexPath, JSON.stringify(index, null, 2))
    ' resources/plugins/launch/bundled-plugins.json $plugin

    # Official skill installs pin to the tag's commit, which upstream reads from a git checkout.
    substituteInPlace config/scripts/build-identity/build-source-commit.mjs \
      --replace-fail "execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()" "'${sourceCommit}'"
    # Both concern only the upstream AppImage: the glibc floor guards its Ubuntu 20.04 users,
    # and only the AppImage ships the downloaded Node, which the deb and rpm drop again.
    substituteInPlace config/electron-builder.config.cjs \
      --replace-fail 'verifyLinuxGlibcFloor(context.appOutDir, { targetArch })' 'void context.appOutDir'  \
      --replace-fail "appImageNodeRuntime = await placeAppImageNodeRuntime(resourcesDir, targetArch)" ""
    # Upstream builds the Wayland clipboard helper in Docker; buildPhase compiles it instead.
    python3 - <<'PYTHON'
    from pathlib import Path
    path = Path("config/wayland-clipboard-resources.cjs")
    source = path.read_text()
    start = source.index("    [\n      join(root, 'config', 'scripts', 'native-build', 'linux', 'build-wayland-clipboard.mjs')")
    end = source.index("    ],", start) + len("    ],")
    path.write_text(source[:start] + "    ['-e', \"\"]," + source[end:])
    PYTHON

    # Uploaded bundles come from the read-only store, and Orca writes into them after extracting.
    substituteInPlace src/main/ssh/system-transport/system-ssh-file-transfer.ts \
      --replace-fail 'tar -xzf - -C ''${quotePosixShell(remoteDir)}`' \
        'tar -xzf - -C ''${quotePosixShell(remoteDir)} && chmod -R u+w ''${quotePosixShell(remoteDir)}`'
  '';

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    inherit (finalAttrs) env;
    fetcherVersion = 4;
    hash = "sha256-vUQ/owOXyBFFB1sLKmktmltDsGNg6FLdvrDUJB1zGc4=";
  };

  mobilePnpmDeps = fetchPnpmDeps {
    pname = "${finalAttrs.pname}-mobile";
    inherit (finalAttrs) version src;
    inherit pnpm;
    sourceRoot = "${finalAttrs.src.name}/mobile";
    fetcherVersion = 4;
    hash = "sha256-tFEW5EBiql6mSiTRJSJsC+Tq7/7TV8slmPqajoehswU=";
  };

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
    # Upstream's pnpmfile otherwise links node_modules into a global store outside the build.
    ORCA_PNPM_GLOBAL_VIRTUAL_STORE = "0";
  };

  postConfigure = ''
    pnpmDeps=$mobilePnpmDeps pnpmRoot=mobile pnpmConfigHook
    (cd mobile && pnpm run postinstall)
  '';

  buildPhase = ''
    runHook preBuild

    export npm_config_nodedir=${electron.headers}
    pnpm rebuild node-pty @parcel/watcher

    pnpm run build:packages
    pnpm exec tsc -p config/tsconfig.build.cli.json --outDir out --composite false --incremental false
    node config/scripts/cli-build/verify-cli-bin.mjs --fix-executable --fix-package-json
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
          hash = "sha256-mC/CWxgF3IvmYJa5oevK8LVe7DlmtcbuYGkZeXJj1XI=";
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
