{
  bashInteractive,
  beads_rust,
  blender,
  buildEnv,
  cacert,
  caveman,
  claude-code,
  coreutils,
  curl,
  dbus,
  dejavu_fonts,
  diffutils,
  dockerTools,
  fd,
  file,
  fontconfig,
  findutils,
  foot,
  gawk,
  git,
  glibcLocales,
  gnugrep,
  gnused,
  gnutar,
  grim,
  gzip,
  hy3dgen,
  jq,
  less,
  lib,
  liberation_ttf,
  makeFontsConf,
  nix,
  nodejs,
  procps,
  python3,
  ripgrep,
  sway,
  systemd,
  tmux,
  unzip,
  wayvnc,
  which,
  wlrctl,
  writeShellApplication,
  writeShellScriptBin,
  writeText,
  wtype,
  xwayland,
  xz,
}:

let
  claude = writeShellScriptBin "claude" ''
    exec ${lib.getExe claude-code} --plugin-dir ${caveman} "$@"
  '';

  env = buildEnv {
    name = "agent-sandbox-env";
    paths = [
      bashInteractive
      beads_rust
      blender
      claude
      coreutils
      curl
      dbus
      diffutils
      fd
      file
      findutils
      foot
      gawk
      git
      gnugrep
      gnused
      gnutar
      grim
      gzip
      jq
      less
      nix
      nodejs
      procps
      (python3.withPackages (_: [ hy3dgen ]))
      ripgrep
      sway
      tmux
      unzip
      wayvnc
      which
      wlrctl
      wtype
      xwayland
      xz
    ];
  };

  entrypoint = writeShellApplication {
    name = "agent-sandbox-entrypoint";
    text = builtins.readFile ./entrypoint.sh;
  };

  nixConf = writeText "nix.conf" ''
    experimental-features = nix-command flakes
  '';

  # The image carries no store paths: the launcher mounts the host store read-only,
  # which also resolves the /run/opengl-driver symlinks that the NVIDIA CDI spec mounts.
  image = dockerTools.streamLayeredImage {
    name = "agent-sandbox";
    includeStorePaths = false;
    extraCommands = ''
      mkdir -p bin usr/bin etc/nix etc/claude-code etc/sway etc/fonts tmp
      ln -s ${bashInteractive}/bin/bash bin/sh
      ln -s ${bashInteractive}/bin/bash bin/bash
      ln -s ${coreutils}/bin/env usr/bin/env
      ln -s ${nixConf} etc/nix/nix.conf
      ln -s ${fontconfig.out}/etc/fonts/conf.d etc/fonts/conf.d
      ln -s ${./sway.conf} etc/sway/config
      ln -s ${./CLAUDE.md} etc/claude-code/CLAUDE.md
      echo 'hosts: files dns' > etc/nsswitch.conf
    '';
    config = {
      Entrypoint = [ (lib.getExe entrypoint) ];
      Cmd = [
        "claude"
        "--dangerously-skip-permissions"
      ];
      Env = [
        "PATH=${env}/bin:/usr/bin"
        "LANG=C.UTF-8"
        "CLAUDE_CODE_SANDBOXED=1"
        "LOCALE_ARCHIVE=${glibcLocales}/lib/locale/locale-archive"
        "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
        "NIX_SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
        "FONTCONFIG_FILE=${
          makeFontsConf {
            fontDirectories = [
              dejavu_fonts
              liberation_ttf
            ];
          }
        }"
        "NIX_REMOTE=daemon"
        "DISABLE_AUTOUPDATER=1"
        "DBUS_SESSION_BUS_CONFIG=${dbus}/share/dbus-1/session.conf"
        "WLR_BACKENDS=headless"
        "WLR_HEADLESS_OUTPUTS=1"
        "WLR_LIBINPUT_NO_DEVICES=1"
        "XDG_SESSION_TYPE=wayland"
        "WAYLAND_DISPLAY=wayland-1"
        "MOZ_ENABLE_WAYLAND=1"
        "NIXOS_OZONE_WL=1"
      ];
    };
  };
in
writeShellApplication {
  name = "agent-sandbox";
  runtimeInputs = [
    coreutils
    systemd
  ];
  runtimeEnv = {
    AGENT_SANDBOX_IMAGE = image;
    AGENT_SANDBOX_REF = "${image.imageName}:${image.imageTag}";
  };
  text = builtins.readFile ./agent-sandbox.sh;
  meta = {
    description = "Run Claude Code in a Docker sandbox with the GPU and a headless Wayland session";
    platforms = lib.platforms.linux;
  };
}
