{
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cacert,
  cairo,
  coreutils,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  glib,
  glibc,
  gtk3,
  icu,
  krb5,
  lib,
  libdrm,
  libGL,
  libglvnd,
  libice,
  libpulseaudio,
  libsm,
  libuuid,
  libx11,
  libxcb,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxinerama,
  libxkbcommon,
  libxrandr,
  libxrender,
  libxscrnsaver,
  libxtst,
  mesa,
  ncurses,
  nspr,
  nss,
  openssl,
  pango,
  python3,
  runCommand,
  stdenv,
  symlinkJoin,
  systemd,
  unzip,
  vulkan-loader,
  wayland,
  writeShellScriptBin,
  zlib,
}:
let
  python = python3.withPackages (p: [
    p.mcp
    p.tomlkit
  ]);
  libraries = [
    alsa-lib
    atk
    at-spi2-atk
    at-spi2-core
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    glib
    glibc
    gtk3
    icu
    krb5
    libdrm
    libGL
    libglvnd
    libpulseaudio
    libuuid
    libxkbcommon
    mesa
    ncurses
    nspr
    nss
    openssl
    pango
    stdenv.cc.cc.lib
    systemd
    vulkan-loader
    wayland
    zlib
  ];
  x11Libraries = [
    libice
    libsm
    libx11
    libxcb
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxinerama
    libxrandr
    libxrender
    libxscrnsaver
    libxtst
  ];
  libraryPath = lib.makeLibraryPath (libraries ++ x11Libraries) + ":/run/opengl-driver/lib";
  tool = writeShellScriptBin "unreal-sandbox" ''
    export UNREAL_RUNTIME_LIBRARY_PATH=${lib.escapeShellArg libraryPath}
    export PATH=${
      lib.makeBinPath [
        coreutils
        unzip
      ]
    }:"$PATH"
    exec ${lib.getExe python} ${./unreal-sandbox.py} "$@"
  '';
  subcommand =
    name: command:
    writeShellScriptBin name ''
      exec ${lib.getExe tool} ${command} "$@"
    '';
in
{
  inherit libraryPath;
  installer = subcommand "agent-sandbox-install-unreal" "install";
  tests =
    runCommand "unreal-sandbox-tests" { SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt"; }
      ''
        cp ${./unreal-sandbox.py} unreal-sandbox.py
        cp ${./test-unreal-sandbox.py} test-unreal-sandbox.py
        ${lib.getExe python} test-unreal-sandbox.py -v
        touch $out
      '';
  tools = symlinkJoin {
    name = "unreal-sandbox-tools";
    paths = [
      tool
      (subcommand "UnrealEditor" "editor")
      (subcommand "RunUAT" "uat")
    ];
  };
}
