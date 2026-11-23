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
  wrapGAppsHook3,
  at-spi2-core,
  gobject-introspection,
  glib,
  git,
  gsettings-desktop-schemas,
  gtk3,
  python3,
  wayland,
  vulkan-loader,
  unstable,
  globalSettings ? { },
  approvedPlugins ? [ ],
  discordPresenceSettings ? { },
  # Setting key to its lines, e.g. { extraCodexFolders = [ "~/backup/.codex" ]; }.
  usageInsightsSettings ? { },
  # Command that automatic Claude, Codex and Muse resumes in local workspaces run through, as
  # `<command> <agent> ...`.
  agentResumeWrapper ? null,
  # Additional local account homes whose transcripts may be discovered and resumed.
  codexAccountHomes ? [ ],
  # Forces "Share anonymous usage data" in existing profiles; null keeps the profile's choice.
  telemetryOptedIn ? null,
  desktopAssistantCommand ? "tohru",
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
  # Keep the desktop bridge independent of Python environments on the user's PATH.
  computerUsePython = stdenv.mkDerivation {
    pname = "orca-computer-python";
    version = python3.version;
    dontUnpack = true;
    nativeBuildInputs = [
      gobject-introspection
      wrapGAppsHook3
    ];
    buildInputs = [
      at-spi2-core
      gtk3
    ];
    installPhase = ''
      mkdir -p $out/bin
      cat > $out/bin/orca-computer-python <<'SH'
      #!${stdenv.shell}
      exec ${python3.withPackages (ps: [ ps.pygobject3 ])}/bin/python3 "$@"
      SH
      chmod +x $out/bin/orca-computer-python
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      $out/bin/orca-computer-python - <<'PYTHON'
      import gi
      for namespace, version in (("Atspi", "2.0"), ("Gdk", "3.0"), ("GdkPixbuf", "2.0"), ("GdkX11", "3.0")):
          gi.require_version(namespace, version)
      from gi.repository import Atspi, Gdk, GdkPixbuf, GdkX11, Gio, GLib
      PYTHON
    '';
  };
  discord-presence = fetchFromGitHub {
    owner = "jondmarien";
    repo = "orca-discord-presence";
    rev = "f0ac386a8f013ef89927dd42b9ad4ab6c8c05324";
    hash = "sha256-06QILPJFKilluXh8EaBXDtVRUyHirikBJLe7JRjZuZM=";
  };
  usage-insights = fetchFromGitHub {
    owner = "Etherll";
    repo = "orca-usage-insights";
    # v1.2.1
    rev = "eae3fa08f21323c5679a7dbbeced2a1777a272a1";
    hash = "sha256-U2ptKTryfYbkP8Kbsnm1rEpXA0axxhO9zath37Mt4CU=";
  };
  sourceCommit = "5dc5548b4570b276f231d81fbb51f8f7a066e40d";
  arch = stdenv.hostPlatform.node.arch;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "orca-ade";
  version = "1.4.268";

  src = fetchFromGitHub {
    owner = "stablyai";
    repo = "orca";
    tag = "v${finalAttrs.version}";
    hash = "sha256-kMXQ8CMfzSRDM97y6ZdYsooI39RTa9KOXOm9kHoxX6k=";
  };

  patches = [
    ./catppuccin-security.patch
    ./glass-titlebar.patch
    ./claude-hooks.patch
    ./open-video-externally.patch
    ./clipboard-shared-media.patch
    ./legacy-plugin-migration.patch
    ./approved-plugins.patch
    ./sandbox-wrapper-deployment.patch
    ./agent-resume-wrapper.patch
    ./sandbox-codex-history.patch
    ./terminal-container-indicators.patch
    ./structured-sandbox-indicators.patch
    ./pending-below-main.patch
    ./desktop-bot-chat.patch
  ];

  postPatch = ''
    substituteInPlace src/main/computer/desktop-script/desktop-script-provider-bridge.ts \
      --replace-fail "linuxPython = 'python3'" "linuxPython = '${computerUsePython}/bin/orca-computer-python'"

    # Apply declarative settings to new and existing profiles at startup,
    # without replacing Orca's mutable workspace/session state.
    cat > src/shared/nix-global-settings.ts <<'EOF'
    import type { GlobalSettings } from './settings/global-settings-types'
    export const nixGlobalSettings = ${builtins.toJSON globalSettings} satisfies Partial<GlobalSettings>
    export const nixTelemetryOptedIn: boolean | null = ${builtins.toJSON telemetryOptedIn}
    EOF
    cat > src/shared/nix-agent-resume-wrapper.ts <<'EOF'
    export const nixAgentResumeWrapper: string | null = ${builtins.toJSON agentResumeWrapper}
    EOF
    cat > src/shared/nix-codex-account-homes.ts <<'EOF'
    export const nixCodexAccountHomes: readonly string[] = ${builtins.toJSON codexAccountHomes}
    EOF
    # Keep the declarative overrides after the defaults without TS2783's duplicate-key error
    # for overrides also named explicitly in the defaults object.
    sed -i \
      -e "1i import { nixGlobalSettings } from '../nix-global-settings'" \
      -e 's/^  return {$/  return Object.assign<GlobalSettings, Partial<GlobalSettings>>({/' \
      -e 's/^  }$/  }, nixGlobalSettings)/' \
      src/shared/settings/default-global-settings.ts
    # Loading re-normalizes some saved fields after spreading them, so the overrides wrap the result.
    sed -i "1i import { nixGlobalSettings, nixTelemetryOptedIn } from '../../../../shared/nix-global-settings'" \
      src/main/persistence/loading-store/profile-loading/normalize-loaded-global-settings.ts
    substituteInPlace src/main/persistence/loading-store/profile-loading/normalize-loaded-global-settings.ts \
      --replace-fail 'export function normalizeLoadedGlobalSettings(' 'function normalizeLoadedGlobalSettingsUpstream('
    cat >> src/main/persistence/loading-store/profile-loading/normalize-loaded-global-settings.ts <<'EOF'
    export function normalizeLoadedGlobalSettings(
      ...args: Parameters<typeof normalizeLoadedGlobalSettingsUpstream>
    ): PersistedState['settings'] {
      const settings = { ...normalizeLoadedGlobalSettingsUpstream(...args), ...nixGlobalSettings }
      // The telemetry block also holds the install ID and experiment cohorts, so only consent is forced.
      return nixTelemetryOptedIn === null || !settings.telemetry
        ? settings
        : { ...settings, telemetry: { ...settings.telemetry, optedIn: nixTelemetryOptedIn } }
    }
    EOF

    # Declared plugins run without the consent prompt; disabling one still sticks.
    cat > src/shared/plugins/approval/nix-approved-plugins.ts <<'EOF'
    export const nixApprovedPlugins: readonly string[] = ${builtins.toJSON approvedPlugins}
    EOF

    # Native local-folder installs retain declared publisher identities and plugin data.
    launch=nix-plugins
    mkdir -p $launch/chron0.discord-presence $launch/etherll.usage-insights
    cp -r ${discord-presence}/{orca-plugin.json,README.md,dist,panel,assets} $launch/chron0.discord-presence
    cp -r ${usage-insights}/{orca-plugin.json,README.md,LICENSE,images,panel,src} $launch/etherll.usage-insights
    chmod -R u+w $launch/chron0.discord-presence $launch/etherll.usage-insights
    # Keep the installed identity and settings when upstream changes its publisher. Saved
    # settings still win over manifest defaults.
    python3 - ${lib.escapeShellArg (builtins.toJSON usageInsightsSettings)} <<'PYTHON'
    import json
    import sys
    from pathlib import Path
    launch = Path("nix-plugins")
    for key in ("chron0.discord-presence", "etherll.usage-insights"):
        path = launch / key / "orca-plugin.json"
        manifest = json.loads(path.read_text())
        manifest["publisher"] = key.split(".")[0]
        if key == "etherll.usage-insights":
            settings = {s["key"]: s for s in manifest["contributes"]["settings"]}
            for name, lines in json.loads(sys.argv[1]).items():
                settings[name]["default"] = "\n".join(lines)
        path.write_text(json.dumps(manifest, indent=2) + "\n")
    PYTHON
    # Saved settings still win over these defaults.
    substituteInPlace $launch/chron0.discord-presence/dist/main.js \
      --replace-fail 'var BOOLEAN_FIELDS = ' ${lib.escapeShellArg "DEFAULT_SETTINGS = Object.freeze({ ...DEFAULT_SETTINGS, ...${builtins.toJSON discordPresenceSettings} }); var BOOLEAN_FIELDS = "} \
      --replace-fail 'normalizeOpenUrl(source.openUrl);' 'normalizeOpenUrl(source.openUrl ?? DEFAULT_SETTINGS.openUrl);' \
      --replace-fail 'normalizeBridgeUrl(source.bridgeUrl);' 'normalizeBridgeUrl(source.bridgeUrl ?? DEFAULT_SETTINGS.bridgeUrl);' \
      --replace-fail 'normalizeBridgeToken(source.bridgeToken);' 'normalizeBridgeToken(source.bridgeToken ?? DEFAULT_SETTINGS.bridgeToken);' \
      --replace-fail 'return "Working in Orca";' 'return "Working in Orca ADE";'
    cp -r ${./catppuccin} $launch/local.catppuccin-mocha
    chmod -R u+w $launch/local.catppuccin-mocha
    # Native same-byte reinstalls preserve prior provenance. Bind the immutable content to
    # this store source so both the legacy migration and later generations publish a new source.
    for key in chron0.discord-presence etherll.usage-insights local.catppuccin-mocha; do
      printf '{"source":"%s"}\n' "$out/share/orca-ade/plugins/$key" > "$launch/$key/nix-installation.json"
    done

    # Exercise the native APIs and portable deployment without touching a running runtime.
    cp ${./native-migration.test.ts} src/main/native-chat/nix-native-migration.test.ts
    cp ${./sandbox-launch.sh} nix-sandbox-launch.sh
    printf '%s' ${finalAttrs.passthru.orcadTemplate} > nix-orcad-template-path

    # Official skill installs pin to the tag's commit, which upstream reads from a git checkout.
    substituteInPlace config/scripts/build-identity/build-source-commit.mjs \
      --replace-fail "execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()" "'${sourceCommit}'"
    # Both concern only the upstream AppImage: the glibc floor guards its Ubuntu 20.04 users,
    # and only the AppImage ships the downloaded Node, which the deb and rpm drop again.
    substituteInPlace config/electron-builder.config.cjs \
      --replace-fail 'verifyLinuxGlibcFloor(context.appOutDir, { targetArch })' 'void context.appOutDir'  \
      --replace-fail "appImageNodeRuntime = await placeAppImageNodeRuntime(resourcesDir, targetArch)" ""
    # Upstream builds the provider exec helper and journal lock in Docker; the host compiler
    # builds them instead.
    substituteInPlace config/provider-exec-resources.cjs \
      --replace-fail "'build-provider-exec.mjs')," "'build-provider-exec.mjs'), '--host-compiler',"
    substituteInPlace config/electron-builder.config.cjs \
      --replace-fail "glibcFloor: context.electronPlatformName === 'linux' ? 'desktop' : false" "glibcFloor: false"
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
    substituteInPlace src/main/ssh/system-transport/file-transfer/system-ssh-file-transfer.ts \
      --replace-fail 'tar -xzf - -C ''${quotePosixShell(remoteDir)}`' \
        'tar -xzf - -C ''${quotePosixShell(remoteDir)} && chmod -R u+w ''${quotePosixShell(remoteDir)}`'
  '';

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    inherit (finalAttrs) env;
    fetcherVersion = 4;
    hash = "sha256-bLn0P+PYX65arwAwqKxHjOGgdys3kuezGEWgi7bB3VU=";
  };

  mobilePnpmDeps = fetchPnpmDeps {
    pname = "${finalAttrs.pname}-mobile";
    inherit (finalAttrs) version src;
    inherit pnpm;
    sourceRoot = "${finalAttrs.src.name}/mobile";
    fetcherVersion = 4;
    hash = "sha256-cXJzIshOyRPlJjwkzD3Q4g+XzZQpbXnWLS4rcNSCAj8=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    copyDesktopItems
    git
    makeBinaryWrapper
    nodejs_24
    pnpm
    pnpmConfigHook
    python3
  ];

  buildInputs = [
    (lib.getLib stdenv.cc.cc)
    wayland
    vulkan-loader
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
    pnpm exec vitest run --config config/vitest.config.ts \
      src/main/native-chat/nix-native-migration.test.ts \
      src/main/runtime/rpc/methods/nix-desktop-bot.test.ts \
      src/main/bots/bot-chat-session.test.ts \
      src/main/bots/desktop-voice-continuations.test.ts \
      src/main/bots/bot-structured-session-wiring.test.ts \
      src/main/native-chat/agent-session-wire/publication/history/agent-read-journal-page.test.ts \
      src/main/native-chat/agent-session-wire/host/structured-agent-session-conversation-reads.test.ts \
      src/shared/agent-launch/startup/tui-agent-launch-command-override.test.ts \
      src/main/managed-server/install/orcad-remote-launch-file-modes.test.ts \
      src/main/native-chat/nix-sandbox-launch-environment.test.ts \
      src/main/codex-accounts/runtime-home/routing/runtime-home-sandbox-session-discovery.test.ts \
      src/main/runtime/agent-session/ownership/agent-session-reservation-admission.test.ts \
      src/main/runtime/agent-session/installation/nix-sandbox-launch-integration.test.ts \
      src/renderer/src/components/StructuredSessionSandboxBadge.test.tsx \
      src/renderer/src/components/TerminalContainerBadge.test.tsx \
      src/renderer/src/lib/terminal-container-state.test.ts \
      src/shared/terminal/output/terminal-container-report.test.ts \
      src/shared/terminal/output/terminal-container-relay.test.ts \
      src/main/runtime/construction/orca-runtime.test.ts
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
    # Koffi ships both libc variants; this package runs on glibc.
    find $out/libexec/orca-ade/resources -type d -path '*/@koromix/koffi-linux-*/musl_*' \
      -prune -exec rm -r {} +
    find $out/libexec/orca-ade/resources -path '*/agent-browser/bin/agent-browser-*' \
      ! -name 'agent-browser-linux-${arch}' -delete
    ln -s ${finalAttrs.passthru.orcadTemplate} $out/libexec/orca-ade/resources/orcad-template
    install -Dm444 resources/icon.png $out/share/icons/hicolor/512x512/apps/orca-ade.png
    mkdir -p $out/share/orca-ade
    cp -r skills $out/share/orca-ade/skills
    cp -r nix-plugins $out/share/orca-ade/plugins

    wrapProgram $out/libexec/orca-ade/orca-ide \
      --set ORCA_DESKTOP_ASSISTANT_COMMAND ${lib.escapeShellArg desktopAssistantCommand} \
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

  passthru.computerUsePython = computerUsePython;

  # SSH and WSL hosts run orcad from this template. Its prebuilt addons cover every remote
  # target, which only upstream's release pipeline builds, and its manifest pins their hashes.
  passthru.orcadTemplate =
    runCommand "orca-ade-orcad-template-${finalAttrs.version}"
      {
        src = fetchurl {
          url = "https://github.com/stablyai/orca/releases/download/v${finalAttrs.version}/orca-ide_${finalAttrs.version}_amd64.deb";
          hash = "sha256-zgiqS7BZcu46zIn2yXzmFAyEAUoUsMfnD+bs4bQLKKc=";
        };
        nativeBuildInputs = [
          dpkg
          python3
        ];
      }
      ''
        dpkg --fsys-tarfile $src | tar --extract ./opt/Orca/resources/orcad-template
        mv opt/Orca/resources/orcad-template $out
        # The materializer copies and verifies this common resource for every SSH target.
        install -Dm755 ${./sandbox-launch.sh} $out/bin/orca-sandbox-launch
        chmod u+w $out/orcad-template.json
        python3 - "$out" <<'PYTHON'
        import hashlib
        import json
        import sys
        from pathlib import Path
        root = Path(sys.argv[1])
        path = root / "orcad-template.json"
        manifest = json.loads(path.read_text())
        name = "bin/orca-sandbox-launch"
        manifest["commonSha256"][name] = hashlib.sha256((root / name).read_bytes()).hexdigest()
        path.write_text(json.dumps(manifest, indent=2) + "\n")
        PYTHON
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
