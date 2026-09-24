{
  lib,
  stdenv,
  fetchurl,
  asar,
  autoPatchelfHook,
  dpkg,
  makeWrapper,
  wrapGAppsHook3,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  bash,
  cairo,
  coreutils,
  cups,
  dbus,
  expat,
  glib,
  gtk3,
  libappindicator-gtk3,
  libdrm,
  libgbm,
  libGL,
  libnotify,
  libpulseaudio,
  libsecret,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  libxtst,
  nspr,
  nss,
  pango,
  pipewire,
  procps,
  replaceVars,
  systemd,
  # A directory holding claude.css, injected into the claude.ai pages the app loads, shell.css,
  # injected into the window's own page beneath them, the title-bar-symbol color for the native
  # window controls in dark mode, and code-theme-dark, the Shiki theme pinned as the dark code
  # theme. The main window becomes transparent, so the CSS paints its title bar as glass.
  theme ? null,
  wayland,
  xdg-utils,
}:

let
  themeHook = replaceVars ./theme.js { inherit theme; };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "claude-desktop";
  version = "2.7032.0";

  src = fetchurl {
    url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${finalAttrs.version}_amd64.deb";
    hash = "sha256-Hn9FBLylsvay08QSPRRdcnZH538u4tBGhQcR5h59exE=";
  };

  nativeBuildInputs = [
    asar
    autoPatchelfHook
    dpkg
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    cairo
    cups
    dbus
    expat
    glib
    gtk3
    libdrm
    libgbm
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    libxtst
    nspr
    nss
    pango
  ];

  # Chromium dlopens these.
  runtimeDependencies = [
    libappindicator-gtk3
    libGL
    libnotify
    libpulseaudio
    libsecret
    pipewire
    (lib.getLib systemd)
    wayland
  ];

  unpackPhase = ''
    runHook preUnpack
    # dpkg -x refuses the setuid chrome-sandbox.
    dpkg --fsys-tarfile $src | tar --extract
    runHook postUnpack
  '';

  dontBuild = true;
  dontWrapGApps = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp -r usr/lib usr/share $out
    rm -r $out/share/lintian
    app=$out/lib/claude-desktop

    # It can't be setuid in the store; Chromium uses user namespaces instead.
    rm $app/chrome-sandbox

    # Cowork's VM. Without qemu and OVMF the app reports it unsupported anyway.
    rm $app/resources/{cowork-linux-helper,smol-bin.x64.img,virtiofsd*}

    # The app hardcodes FHS paths. Fail if an update moves one, so it isn't silently lost.
    asar extract $app/resources/app.asar asar
    replaceRaw() {
      local files
      mapfile -t files < <(grep -rlF -- "$1" asar)
      if [ ''${#files[@]} -eq 0 ]; then
        echo "app.asar no longer contains $1" >&2
        exit 1
      fi
      sed -i "s|$1|$2|g" "''${files[@]}"
    }
    replace() {
      replaceRaw "\"$1\"" "\"$2\""
    }
    replace /bin/bash ${lib.getExe bash}
    replace /bin/ps ${procps}/bin/ps
    replace /usr/bin/pgrep ${procps}/bin/pgrep
    replace /usr/bin/busctl ${systemd}/bin/busctl
    replace /usr/bin/secret-tool ${libsecret}/bin/secret-tool
    ${lib.optionalString (theme != null) ''
      replace '#151515' '#00000000'
      replace '#c2c0b6' "$(< ${theme}/title-bar-symbol)"
      replaceRaw 'titleBarStyle:"hidden",titleBarOverlay:!0,' 'titleBarStyle:"hidden",titleBarOverlay:!0,transparent:!0,'

      # The hook goes after the directive so the minified main keeps strict mode.
      main=asar/.vite/build/index.pre.js
      if [ "$(head -c 13 $main)" != '"use strict";' ]; then
        echo "$main no longer starts with \"use strict\";" >&2
        exit 1
      fi
      { printf '"use strict";'; cat ${themeHook}; tail -c +14 $main; } > main.js
      mv main.js $main
    ''}
    rm -r $app/resources/app.asar $app/resources/app.asar.unpacked
    asar pack asar $app/resources/app.asar \
      --unpack '*.node' --unpack-dir resources/github-mcp

    # A shell and JavaScript polyglot: each shell line starts with a path that is also a JS comment.
    substituteInPlace $app/resources/claude-browser-shim.js \
      --replace-fail //usr/bin/true /${coreutils}/bin/true

    runHook postInstall
  '';

  preFixup = ''
    makeWrapper $out/lib/claude-desktop/claude-desktop $out/bin/claude-desktop \
      "''${gappsWrapperArgs[@]}" \
      --prefix PATH : ${lib.makeBinPath [ xdg-utils ]}
  '';

  meta = {
    description = "Anthropic's official Claude desktop app";
    homepage = "https://claude.com/download";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "claude-desktop";
  };
})
