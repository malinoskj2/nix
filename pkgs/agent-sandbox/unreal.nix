{ pkgs, lib }:
let
  python = pkgs.python3.withPackages (p: [
    p.mcp
    p.tomlkit
  ]);
  libraries = with pkgs; [
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
  runtime = lib.makeLibraryPath libraries + ":/run/opengl-driver/lib";
  tool = pkgs.writeShellScriptBin "unreal-sandbox" ''
    export UNREAL_RUNTIME_LIBRARY_PATH=${lib.escapeShellArg runtime}
    export PATH=${
      lib.makeBinPath [
        pkgs.unzip
        pkgs.coreutils
      ]
    }:"$PATH"
    exec ${python}/bin/python ${./unreal-sandbox.py} "$@"
  '';
  editor = pkgs.writeShellScriptBin "UnrealEditor" ''
    exec ${tool}/bin/unreal-sandbox editor "$@"
  '';
  uat = pkgs.writeShellScriptBin "RunUAT" ''
    exec ${tool}/bin/unreal-sandbox uat "$@"
  '';
in
{
  inherit runtime;
  installer = pkgs.writeShellScriptBin "agent-sandbox-install-unreal" ''
    exec ${tool}/bin/unreal-sandbox install "$@"
  '';
  tests =
    pkgs.runCommand "unreal-sandbox-tests"
      {
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      }
      ''
        mkdir source
        cp ${./unreal-sandbox.py} source/unreal-sandbox.py
        cp ${./test-unreal-sandbox.py} source/test-unreal-sandbox.py
        cd source
        ${python}/bin/python test-unreal-sandbox.py -v
        touch $out
      '';
  package = pkgs.symlinkJoin {
    name = "unreal-sandbox-tools";
    paths = [
      tool
      editor
      uat
    ];
  };
}
