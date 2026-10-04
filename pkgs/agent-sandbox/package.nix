{
  bashInteractive,
  blender,
  buildEnv,
  cacert,
  chromium,
  claude-code,
  codex,
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
  gcc,
  git,
  glibc,
  glibcLocales,
  gnugrep,
  gnumake,
  gnused,
  gnutar,
  grim,
  gzip,
  hy3dgen,
  hyprland,
  inotify-tools,
  jq,
  less,
  lib,
  liberation_ttf,
  makeFontsConf,
  mold,
  nix,
  nodejs,
  opencode,
  orca-ade,
  openssh,
  playwright-driver,
  playwright-mcp,
  playwright-test,
  procps,
  python3,
  ripgrep,
  runCommand,
  sccache,
  sway,
  symlinkJoin,
  systemd,
  tmux,
  tzdata,
  unzip,
  wayvnc,
  which,
  wl-clipboard,
  wlrctl,
  writeShellApplication,
  writeShellScriptBin,
  writeText,
  wtype,
  xwayland,
  xz,
  zcode,
}:

let
  # cudaSupport enables Cycles' CUDA and OptiX devices. Blender compiles CUDA kernels for every
  # architecture by default; the RTX 5090 only needs sm_120.
  blender' = (blender.override { cudaSupport = true; }).overrideAttrs (old: {
    cmakeFlags = old.cmakeFlags ++ [ (lib.cmakeFeature "CYCLES_CUDA_BINARIES_ARCH" "sm_120") ];
  });

  # Chromium's setuid and user-namespace sandboxes can't start inside the container.
  chromium' = chromium.override { commandLineArgs = "--no-sandbox --test-type"; };

  plugin = runCommand "agent-sandbox-plugin" { } ''
    install -Dm644 ${
      writeText "plugin.json" (builtins.toJSON { name = "agent-sandbox"; })
    } $out/.claude-plugin/plugin.json
    install -Dm644 ${
      writeText "mcp.json" (
        builtins.toJSON {
          mcpServers.playwright = {
            command = lib.getExe playwright-mcp;
            args = [
              "--output-dir"
              "/tmp/playwright-mcp"
            ];
          };
        }
      )
    } $out/.mcp.json
  '';

  # Orca's relay installs its Claude hooks here rather than in the read-only ~/.claude/settings.json.
  claude = writeShellScriptBin "claude" ''
    settings=''${AGENT_SANDBOX_CLAUDE_SETTINGS:-$HOME/.orca/agent-hooks/claude-settings.json}
    if [[ -f $settings ]]; then
      set -- --settings "$settings" "$@"
    fi
    exec ${lib.getExe claude-code} --plugin-dir ${plugin} "$@"
  '';

  # The sandbox keeps a separate writable Codex home so project trust can persist,
  # which means later host config changes do not reach an existing SSH sandbox.
  codex' = writeShellScriptBin "codex" ''
    exec ${lib.getExe codex} --no-alt-screen "$@"
  '';

  # The desktop CLI connects to its Unix runtime socket through the read-only
  # ~/.config/orca mount. The Electron app itself is never started here.
  orcaCli = writeShellScriptBin "orca-ide" ''
    exec ${lib.getExe orca-ade} "$@"
  '';

  orcaCurl = writeShellApplication {
    name = "curl";
    runtimeEnv.AGENT_SANDBOX_REAL_CURL = lib.getExe curl;
    text = builtins.readFile ./orca-curl.sh;
  };

  hookProxy = writeShellScriptBin "agent-sandbox-hook-proxy" ''
    exec ${lib.getExe python3} ${./hook-proxy.py} "$@"
  '';

  prepareOrcaHooks = writeShellScriptBin "agent-sandbox-prepare-orca-hooks" ''
    exec ${lib.getExe python3} ${./prepare-orca-hooks.py} "$@"
  '';

  # The desktop's pinned Hyprland, able to nest in the headless sway on the NVIDIA GPU: sway offers
  # xdg_wm_base 5, not the 6 Aquamarine asks for, and NVIDIA's GBM can neither allocate the linear
  # buffers Aquamarine requests for a nested output nor import the implicit-modifier ones it falls
  # back to.
  hyprland' = hyprland.override (old: {
    aquamarine = old.aquamarine.overrideAttrs (aquamarine: {
      patches = (aquamarine.patches or [ ]) ++ [ ./aquamarine-nested.patch ];
    });
  });

  nestedHyprland = writeShellApplication {
    name = "agent-sandbox-nested-hyprland";
    runtimeInputs = [
      coreutils
      hyprland'
      jq
      wayvnc
    ];
    runtimeEnv.NESTED_HYPRLAND_CONFIG = ./hyprland.lua;
    text = builtins.readFile ./nested-hyprland.sh;
  };

  # hyprctl needs an instance signature, which an agent's shell never has; there is only one.
  hyprctl = lib.hiPrio (
    writeShellScriptBin "hyprctl" ''
      if [[ -z ''${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
        HYPRLAND_INSTANCE_SIGNATURE=$(${lib.getExe' hyprland' "hyprctl"} instances -j | ${lib.getExe jq} -r '.[0].instance // empty')
        export HYPRLAND_INSTANCE_SIGNATURE
      fi
      exec ${lib.getExe' hyprland' "hyprctl"} "$@"
    ''
  );

  env = buildEnv {
    name = "agent-sandbox-env";
    paths = [
      bashInteractive
      blender'
      chromium'
      claude
      codex'
      coreutils
      curl
      dbus
      diffutils
      fd
      file
      findutils
      foot
      gawk
      gcc
      git
      gnugrep
      gnumake
      gnused
      gnutar
      grim
      gzip
      hyprctl
      hyprland'
      inotify-tools
      jq
      less
      mold
      nestedHyprland
      nix
      nodejs
      opencode
      orcaCli
      playwright-test
      procps
      (python3.withPackages (_: [ hy3dgen ]))
      ripgrep
      sccache
      sway
      tmux
      unzip
      wayvnc
      which
      wl-clipboard
      wlrctl
      wtype
      xwayland
      xz
      zcode
    ];
  };

  entrypoint = writeShellApplication {
    name = "agent-sandbox-entrypoint";
    text = builtins.readFile ./entrypoint.sh;
  };

  clipboardSync = writeShellApplication {
    name = "agent-sandbox-clipboard-sync";
    text = builtins.readFile ./clipboard-sync.sh;
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
      mkdir -p bin usr/bin lib64 etc/nix etc/claude-code etc/sway etc/fonts tmp
      ln -s ${bashInteractive}/bin/bash bin/sh
      ln -s ${bashInteractive}/bin/bash bin/bash
      ln -s ${coreutils}/bin/env usr/bin/env
      ln -s ${orcaCli}/bin/orca-ide usr/bin/orca-ide
      # For prebuilt binaries such as the Claude CLI that Claude Desktop installs over SSH.
      ln -s ${glibc}/lib/ld-linux-x86-64.so.2 lib64/ld-linux-x86-64.so.2
      ln -s ${nixConf} etc/nix/nix.conf
      ln -s ${fontconfig.out}/etc/fonts/conf.d etc/fonts/conf.d
      ln -s ${tzdata}/share/zoneinfo etc/zoneinfo
      ln -s ${./sway.conf} etc/sway/config
      ln -s ${./nested-sway.conf} etc/sway/nested
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
        "ORCA_CLI_COMMAND=orca-ide"
        "LOCALE_ARCHIVE=${glibcLocales}/lib/locale/locale-archive"
        # As on NixOS: the host's /etc/localtime is mounted, and a TZ that names a zone resolves
        # through TZDIR for glibc and /etc/zoneinfo for readers that ignore TZDIR, such as chrono.
        "TZDIR=/etc/zoneinfo"
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
        "PLAYWRIGHT_BROWSERS_PATH=${playwright-driver.browsers}"
        "PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true"
        "CARGO_PROFILE_DEV_DEBUG=line-tables-only"
        "CARGO_PROFILE_TEST_DEBUG=line-tables-only"
        "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS=-C link-arg=-fuse-ld=mold"
        # The cache lands in the sandboxes' shared home, never the host's: a sandbox must not
        # write objects the host links. Each container runs its own server, so each enforces
        # the size cap on its own.
        "RUSTC_WRAPPER=sccache"
        "SCCACHE_CACHE_SIZE=50G"
      ];
    };
  };

  launcher = writeShellApplication {
    name = "agent-sandbox";
    runtimeInputs = [
      clipboardSync
      coreutils
      openssh
      systemd
      wl-clipboard
    ];
    runtimeEnv = {
      AGENT_SANDBOX_IMAGE = image;
      # Prefix numeric-leading tags so ShellCheck does not mistake the generated
      # environment assignment for arithmetic (SC2100).
      AGENT_SANDBOX_TAG = "hash-${image.imageTag}";
    };
    text = builtins.readFile ./agent-sandbox.sh;
  };

  ssh = writeShellApplication {
    name = "agent-sandbox-ssh";
    runtimeInputs = [
      coreutils
      systemd
    ];
    runtimeEnv.AGENT_SANDBOX_SSHD = lib.getExe' openssh "sshd";
    text = builtins.readFile ./agent-sandbox-ssh.sh;
  };

  execAgent = writeShellApplication {
    name = "agent-sandbox-exec";
    runtimeInputs = [
      coreutils
      gnugrep
      systemd
    ];
    runtimeEnv = {
      AGENT_SANDBOX_HOOK_PROXY = lib.getExe hookProxy;
      AGENT_SANDBOX_PREPARE_ORCA_HOOKS = lib.getExe prepareOrcaHooks;
      AGENT_SANDBOX_ORCA_PATH = "${orcaCurl}/bin:${env}/bin:/usr/bin";
    };
    text = builtins.readFile ./agent-sandbox-exec.sh;
  };
in
symlinkJoin {
  name = "agent-sandbox";
  paths = [
    launcher
    ssh
    execAgent
  ];
  meta = {
    description = "Run Claude Code, Codex or ZCode in a Docker sandbox with the GPU and a headless Wayland session";
    mainProgram = "agent-sandbox";
    platforms = lib.platforms.linux;
  };
}
