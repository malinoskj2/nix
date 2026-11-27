{
  agent-push,
  antigravity-cli,
  at-spi2-core,
  bacon,
  bashInteractive,
  binutils,
  bzip2,
  bat,
  bc,
  betterleaks-push-gate,
  blender,
  btop,
  buildEnv,
  cacert,
  callPackage,
  cargo,
  cargo-audit,
  cargo-deny,
  cargo-nextest,
  cargo-preferences,
  chromium,
  clang,
  claude-code,
  clippy,
  codex,
  coreutils,
  curl,
  dbus,
  dejavu_fonts,
  diffutils,
  dig,
  docker,
  docker-buildx,
  docker-client,
  docker-compose,
  dockerTools,
  envsubst,
  eza,
  fd,
  ffmpeg,
  file,
  findutils,
  fontconfig,
  foot,
  gawk,
  gcc,
  ghidra,
  getent,
  git,
  git-commitu,
  git-open-branch,
  glib,
  glibc,
  glibcLocales,
  gnugrep,
  gnumake,
  gnupg,
  gnused,
  gnutar,
  gobject-introspection,
  grim,
  frame-interpolation,
  gpu-scheduler,
  host-switch,
  gzip,
  htop-vim-navigation,
  hy3dgen,
  hyprland,
  imagemagick,
  inotify-tools,
  iproute2,
  jq,
  killall,
  ktx-tools,
  last30days,
  tiktok-search,
  less,
  lib,
  liberation_ttf,
  libffi,
  libva-utils,
  lldb,
  lua5_4,
  lshw,
  makeFontsConf,
  makeWrapper,
  man-db,
  markdown-to-pdf,
  media-gallery,
  media-transcribe,
  qwen-prompt,
  council,
  mediainfo,
  mold,
  mpv,
  mpvpaper,
  neovim,
  nil,
  nix,
  nix-ld,
  nixfmt,
  nmap,
  nodejs,
  novnc,
  nssTools,
  opencode,
  openssh,
  openssl,
  orca-ade,
  p7zip,
  path,
  pandoc,
  pciutils,
  pipewire,
  pkg-config,
  playwright-browsers,
  playwright-mcp,
  playwright-test,
  postgresql,
  procps,
  pulseaudio,
  pyghidra-mcp,
  python3,
  redis,
  replaceVars,
  ripgrep,
  runCommand,
  rust-analyzer,
  rust-lints,
  rustc,
  rustfmt,
  sccache,
  socat,
  sops,
  sqlite,
  source2viewer-cli,
  stdenv,
  ssh-to-age,
  sway,
  swaybg,
  symlinkJoin,
  systemd,
  tealdeer,
  tmux,
  tokei,
  tree,
  ts-lints,
  tzdata,
  unrar,
  unzip,
  usbutils,
  uv,
  util-linux,
  vim,
  vulkan-tools,
  wayvnc,
  wget,
  which,
  whois,
  wireplumber,
  wl-clipboard,
  wlrctl,
  worktree-closeout,
  writeShellApplication,
  writeShellScriptBin,
  writeText,
  wtype,
  xwayland,
  xz,
  zlib,
  yt-dlp,
  zip,
  zoxide,
  zsh,
}:

let
  unreal = callPackage ./unreal.nix { };
  unrealMcp = import ./unreal-mcp.nix;
  ghidraMcp = import ./ghidra-mcp.nix;
  # cudaSupport enables Cycles' CUDA and OptiX devices. Blender compiles CUDA kernels for every
  # architecture by default; the RTX 5090 only needs sm_120.
  blender' = (blender.override { cudaSupport = true; }).overrideAttrs (old: {
    cmakeFlags = old.cmakeFlags ++ [
      (lib.cmakeFeature "CYCLES_CUDA_BINARIES_ARCH" "sm_120")
      # Otherwise CUDA's split compiler uses every CPU, outside Nix's core budget.
      (lib.cmakeBool "WITH_CYCLES_CUDA_BUILD_SERIAL" true)
    ];
  });

  # Chromium's setuid and user-namespace sandboxes can't start inside the container.
  chromium' = chromium.override { commandLineArgs = "--no-sandbox --test-type"; };

  # Playwright's headless shell always renders with SwiftShader. Its "chromium" channel runs the
  # full browser in new headless mode, which renders on the GPU through ANGLE's Vulkan backend,
  # display or not.
  chromiumGpuArgs = [
    "--use-angle=vulkan"
    "--ignore-gpu-blocklist"
  ];

  browserGpuProbe = writeShellApplication {
    name = "browser-gpu-probe";
    runtimeInputs = [
      gnugrep
      vulkan-tools
    ];
    text = builtins.readFile ./playwright/browser-gpu-probe.sh;
  };

  sandboxPlaywright = runCommand "sandbox-playwright" { } ''
    install -Dm644 ${
      replaceVars ./playwright/sandbox-playwright.js {
        probe = lib.getExe browserGpuProbe;
        gpuArgs = builtins.toJSON chromiumGpuArgs;
      }
    } $out/lib/node_modules/sandbox-playwright/index.js
  '';

  playwrightNodePath = "${sandboxPlaywright}/lib/node_modules:${playwright-test}/lib/node_modules";
  inherit (playwright-browsers) gstPluginSystemPath;

  playwright = symlinkJoin {
    name = "playwright-test-sandbox";
    paths = [ playwright-test ];
    nativeBuildInputs = [ makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/playwright \
        --set-default PLAYWRIGHT_BROWSERS_PATH ${playwright-browsers} \
        --set-default GST_PLUGIN_SYSTEM_PATH_1_0 ${gstPluginSystemPath} \
        --prefix NODE_PATH : ${sandboxPlaywright}/lib/node_modules
    '';
  };

  playwrightMcpConfig =
    args:
    writeText "playwright-mcp.json" (
      builtins.toJSON {
        # Its default persistent profile goes under the read-only browsers path.
        browser.isolated = true;
        browser.launchOptions = {
          channel = "chromium";
          inherit args;
        };
      }
    );

  playwrightMcp = writeShellApplication {
    name = "playwright-mcp";
    runtimeInputs = [ browserGpuProbe ];
    runtimeEnv = {
      # nixpkgs' wrapper sets its own browsers path, which lacks the GStreamer and ffmpeg fixes.
      SANDBOX_PLAYWRIGHT_MCP = lib.getExe (
        playwright-mcp.override (old: {
          playwright-driver = old.playwright-driver // {
            browsers = playwright-browsers;
          };
        })
      );
      SANDBOX_PLAYWRIGHT_MCP_GPU_CONFIG = playwrightMcpConfig chromiumGpuArgs;
      SANDBOX_PLAYWRIGHT_MCP_CPU_CONFIG = playwrightMcpConfig [ ];
    };
    text = builtins.readFile ./playwright/playwright-mcp.sh;
  };

  claudePlugin =
    let
      manifest = writeText "plugin.json" (builtins.toJSON { name = "agent-sandbox"; });
      mcp = writeText "mcp.json" (
        builtins.toJSON {
          mcpServers = {
            playwright = {
              command = lib.getExe playwrightMcp;
              args = [
                "--output-dir"
                "/tmp/playwright-mcp"
              ];
            };
            unreal-mcp = {
              type = "http";
              inherit (unrealMcp) url;
            };
          };
        }
      );
    in
    runCommand "agent-sandbox-plugin" { } ''
      install -Dm644 ${manifest} $out/.claude-plugin/plugin.json
      install -Dm644 ${mcp} $out/.mcp.json
    '';

  # Orca's relay installs its Claude hooks here rather than in the Nix-managed ~/.claude/settings.json.
  claude = writeShellScriptBin "claude" ''
    settings=''${AGENT_SANDBOX_CLAUDE_SETTINGS:-$HOME/.orca/agent-hooks/claude-settings.json}
    if [[ -f $settings ]]; then
      set -- --settings "$settings" "$@"
    fi
    # Child worktrees host short-lived workers, so the 1-hour cache writes would rarely pay off.
    if [[ -n ''${ORCA_AGENT_SESSION_ID:-}''${ORCA_TERMINAL_HANDLE:-}''${ORCA_PANE_KEY:-} ]] &&
      parent=$(${lib.getExe' coreutils "timeout"} 3 ${lib.getExe orcaCli} worktree current --json 2>/dev/null |
        ${lib.getExe jq} -r '.result.worktree.parentWorktreeId // empty' 2>/dev/null) &&
      [[ -n $parent ]]; then
      set -- --settings '{"promptCacheTtl":"5m"}' "$@"
    fi
    exec ${lib.getExe claude-code} --plugin-dir ${claudePlugin} "$@"
  '';

  # The system config outranks the host's ~/.config/opencode/opencode.json mounted under it.
  opencodeSystemConfig = writeText "opencode.json" (
    builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      instructions = [ "${instructions}" ];
      # The container provides isolation, as with the other agents' permission bypasses.
      permissions = [
        {
          action = "*";
          resource = "*";
          effect = "allow";
        }
      ];
      # Never the real key: the egress proxy replaces this header for api.venice.ai.
      providers.venice.settings.apiKey = "agent-egress-placeholder";
      mcp.servers = {
        playwright = {
          type = "local";
          command = [
            (lib.getExe playwrightMcp)
            "--output-dir"
            "/tmp/playwright-mcp"
          ];
        };
        unreal-mcp = {
          type = "remote";
          disabled = true;
          inherit (unrealMcp) url;
          oauth = false;
          timeout.execution = 120000;
        };
        ghidra = {
          type = "local";
          command = [ (lib.getExe pyghidra-mcp) ];
          disabled = !ghidraMcp.enabled;
          timeout = {
            startup = ghidraMcp.startup_timeout_sec * 1000;
            execution = ghidraMcp.tool_timeout_sec * 1000;
          };
        };
      };
    }
  );

  # The sandbox seeds its own writable Codex config once, so project trust persists but later host
  # changes never reach it. MCP servers go in as -c overrides, which apply on every launch.
  codexMcpOverrides = lib.concatLists (
    lib.mapAttrsToList (name: value: [
      "-c"
      "mcp_servers.ghidra.${name}=${builtins.toJSON value}"
    ]) (ghidraMcp // { command = lib.getExe pyghidra-mcp; })
  );

  codex' = writeShellApplication {
    name = "codex";
    # The container provides isolation. Set this before app-server startup checks, too.
    text = ''
      CODEX=${lib.getExe codex}
      set -- --no-alt-screen \
        -c 'sandbox_mode="danger-full-access"' -c 'approval_policy="never"' \
        ${lib.escapeShellArgs codexMcpOverrides} "$@"
    ''
    + builtins.readFile ./codex.sh;
  };

  # The desktop CLI reaches the runtime through the launcher's Orca relay, which
  # the sandbox's own Orca profile names. The Electron app itself is never started here.
  orcaCli = writeShellScriptBin "orca-ide" ''
    exec ${lib.getExe orca-ade} "$@"
  '';

  orcaCurl = writeShellApplication {
    name = "curl";
    runtimeEnv.AGENT_SANDBOX_REAL_CURL = lib.getExe curl;
    text = builtins.readFile ./orca-curl.sh;
  };

  pythonScript =
    name: python: script:
    writeShellScriptBin name ''
      exec ${lib.getExe python} ${script} "$@"
    '';

  hookProxy = pythonScript "agent-sandbox-hook-proxy" python3 ./hook-proxy.py;
  orcaRelay = pythonScript "agent-sandbox-orca-relay" python3 ./orca-relay.py;
  prepareOrcaHooks = pythonScript "agent-sandbox-prepare-orca-hooks" python3 ./prepare-orca-hooks.py;

  egressProxy = "http://127.0.0.1:3128";
  egressEnv = writeText "agent-sandbox-egress.env" (
    lib.concatStrings (
      lib.mapAttrsToList (name: value: "${name}=${value}\n") (
        lib.genAttrs [ "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" "http_proxy" "https_proxy" "all_proxy" ] (
          _: egressProxy
        )
        # Docker's bridge pool: siblings and stacks are reached directly on their internal networks.
        // lib.genAttrs [ "NO_PROXY" "no_proxy" ] (_: "localhost,127.0.0.1,::1,172.16.0.0/12")
        # Tools differ in which variable they read, and NIX_SSL_CERT_FILE overrides SSL_CERT_FILE.
        // lib.genAttrs [
          "SSL_CERT_FILE"
          "NIX_SSL_CERT_FILE"
          "CURL_CA_BUNDLE"
          "REQUESTS_CA_BUNDLE"
          "GIT_SSL_CAINFO"
          "CARGO_HTTP_CAINFO"
          "PIP_CERT"
          "CODEX_CA_CERTIFICATE"
        ] (_: "/run/agent-egress/ca-bundle.crt")
        // {
          NODE_EXTRA_CA_CERTS = "/run/agent-egress/ca.pem";
          NODE_USE_ENV_PROXY = "1";
          AGENT_SANDBOX_EGRESS = "1";
          AGENT_PUSH_SOCKET = "/run/agent-push/push.sock";
        }
      )
    )
  );

  runner = writeShellScriptBin "agent-sandbox-runner" ''
    exec ${lib.getExe python3} ${./runner/runner.py} \
      --docker ${lib.getExe docker-client} \
      --socat ${lib.getExe socat} \
      --compose ${lib.getExe docker-compose} \
      --buildx ${docker-buildx}/libexec/docker/cli-plugins/docker-buildx "$@"
  '';

  runnerClient = writeShellScriptBin "sandbox-runner" ''
    exec ${lib.getExe python3} ${./runner/client.py} "$@"
  '';

  sandboxSmoke = writeShellApplication {
    name = "sandbox-smoke";
    runtimeEnv = {
      SANDBOX_SMOKE_BROWSERS = ./smoke/browsers.js;
      SANDBOX_SMOKE_MCP = ./smoke/mcp.js;
      SANDBOX_PLAYWRIGHT_MCP = lib.getExe playwrightMcp;
    };
    text = builtins.readFile ./smoke/sandbox-smoke.sh;
  };

  # util-linux's kill, more and others collide with coreutils and procps.
  utilLinuxTools = runCommand "util-linux-tools" { } ''
    mkdir -p $out/bin
    for tool in column findmnt flock getopt ionice logger lscpu lsblk nsenter script setsid taskset \
      unshare uuidgen; do
      ln -s ${util-linux.bin}/bin/$tool $out/bin/$tool
    done
  '';

  # Tohru's Lua tests call the versioned name, as Debian installs it.
  lua = symlinkJoin {
    name = "lua-5.4-sandbox";
    paths = [ lua5_4 ];
    postBuild = "ln -s lua $out/bin/lua5.4";
  };

  # Prebuilt programs, uv's Python and the wheels it loads find their libraries through nix-ld:
  # a general set, then the Unreal editor's.
  nixLdLibraryPath =
    lib.makeLibraryPath [
      bzip2
      curl
      libffi
      openssl
      sqlite
      stdenv.cc.cc
      xz
      zlib
    ]
    + ":${unreal.libraryPath}";
  sandboxSteam = pythonScript "sandbox-steam" (python3.withPackages (ps: [
    ps.vdf
  ])) ./sandbox-steam.py;
  codexImage = writeShellScriptBin "codex-image" ''
    exec ${lib.getExe nodejs} ${./codex-image.mjs} "$@"
  '';

  # Sandboxes reach the app-server's socket directly, so the server itself holds every turn to
  # what codex-image asks for.
  codexRequirements = writeText "codex-requirements.toml" ''
    allowed_sandbox_modes = ["read-only"]
    allowed_approval_policies = ["never"]
  '';

  codexServerEntrypoint = writeShellApplication {
    name = "agent-sandbox-codex-server-entrypoint";
    runtimeInputs = [
      jq
      socat
    ];
    runtimeEnv.CODEX = lib.getExe codex;
    text = builtins.readFile ./codex-server-entrypoint.sh;
  };

  # The desktop's pinned Hyprland, patched to nest in the headless sway on the NVIDIA GPU. Sway
  # offers xdg_wm_base 5, not the 6 Aquamarine asks for, and NVIDIA's GBM can neither allocate the
  # linear buffers Aquamarine requests for a nested output nor import the implicit-modifier ones it
  # falls back to.
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
    # Match the host's development and inspection tools so agents can use PATH
    # instead of searching the shared store. Keep GCC as the default C compiler.
    paths = [
      antigravity-cli
      at-spi2-core
      bacon
      bashInteractive
      (lib.hiPrio binutils)
      bat
      bc
      betterleaks-push-gate.betterleaks
      betterleaks-push-gate.gh
      betterleaks-push-gate.git
      blender'
      btop
      cargo
      cargo-audit
      cargo-deny
      cargo-nextest
      cargo-preferences
      chromium'
      (lib.lowPrio clang)
      claude
      clippy
      codex'
      codexImage
      coreutils
      curl
      dbus
      diffutils
      dig
      docker-client
      docker-compose
      envsubst
      eza
      fd
      ffmpeg
      file
      findutils
      foot
      frame-interpolation
      gawk
      (lib.hiPrio gcc)
      ghidra
      git-commitu
      git-open-branch
      glib
      glibc.bin
      gnugrep
      gnumake
      gnupg
      gnused
      gnutar
      gpu-scheduler
      host-switch
      grim
      gzip
      htop-vim-navigation
      hyprctl
      hyprland'
      imagemagick
      inotify-tools
      iproute2
      jq
      killall
      ktx-tools
      last30days
      tiktok-search
      less
      libva-utils
      lldb
      lua
      lshw
      man-db
      markdown-to-pdf
      media-gallery
      media-transcribe
      qwen-prompt
      council
      mediainfo
      mold
      mpv
      mpvpaper
      neovim
      nestedHyprland
      nil
      nix
      nixfmt
      nmap
      nodejs
      opencode
      novnc
      nssTools
      openssh
      orcaCli
      p7zip
      pandoc
      pciutils
      pkg-config
      postgresql
      playwright
      procps
      pipewire
      pulseaudio
      (python3.withPackages (ps: [
        hy3dgen
        ps.pygobject3
        ps.tomli-w
      ]))
      redis
      ripgrep
      agent-push.client
      runnerClient
      rust-analyzer
      rust-lints
      rustc
      rustfmt
      sandboxDisplay
      sandboxSmoke
      sandboxSteam
      sccache
      socat
      sops
      source2viewer-cli
      ssh-to-age
      sway
      swaybg
      tealdeer
      tmux
      tokei
      tree
      ts-lints
      unrar
      unreal.tools
      unzip
      usbutils
      utilLinuxTools
      uv
      vim
      vulkan-tools
      wayvnc
      wget
      which
      whois
      wireplumber
      wl-clipboard
      wlrctl
      worktree-closeout
      wtype
      xwayland
      xz
      yt-dlp
      zip
      zoxide
      zsh
    ];
  };

  sandboxDisplay = writeShellApplication {
    name = "sandbox-display";
    runtimeInputs = [ util-linux ];
    text = builtins.readFile ./sandbox-display.sh;
  };

  entrypoint = writeShellApplication {
    name = "agent-sandbox-entrypoint";
    text = builtins.readFile ./entrypoint.sh;
  };

  nixConf = writeText "nix.conf" ''
    experimental-features = nix-command flakes
  '';

  # Managed settings outrank the user settings the sandbox seeds from the host. Agents never call
  # the LSP tool, and each sandbox's rust-analyzer held several GB.
  claudeManagedSettings = writeText "managed-settings.json" (
    builtins.toJSON {
      enabledPlugins."rust-analyzer-lsp@claude-plugins-official" = false;
    }
  );

  instructions = writeText "agent-sandbox-instructions.md" (
    builtins.readFile ./CLAUDE.md
    + "\n"
    + builtins.readFile ../../users/jesse/claude/rules/gpu.md
    + "\n"
    + builtins.readFile ../../users/jesse/claude/rules/host-switch.md
  );

  caBundle = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  # Docker's own default profile, from the engine the host runs, with the additions that tools in
  # the image were shown to need. Only Steam sandboxes run without seccomp.
  seccompProfile = runCommand "agent-sandbox-seccomp.json" { nativeBuildInputs = [ jq ]; } ''
    jq --slurpfile additions ${./seccomp-additions.json} '.syscalls += $additions[0]' \
      ${docker.moby-src}/vendor/github.com/moby/profiles/seccomp/default.json >$out
  '';

  # The image carries no store paths: the launcher mounts the host store read-only,
  # which also resolves the /run/opengl-driver symlinks that the NVIDIA CDI spec mounts.
  image = dockerTools.streamLayeredImage {
    name = "agent-sandbox";
    includeStorePaths = false;
    extraCommands = ''
      mkdir -p bin usr/bin lib64 etc/nix etc/claude-code etc/opencode etc/sway etc/fonts etc/ssl/certs tmp \
        etc/pipewire/pipewire.conf.d etc/wireplumber/wireplumber.conf.d
      # WebKit's media buffer writes to the hardcoded /var/tmp, which joins the on-disk /tmp.
      mkdir var
      ln -s /tmp var/tmp
      ln -s ${bashInteractive}/bin/bash bin/sh
      ln -s ${bashInteractive}/bin/bash bin/bash
      ln -s ${coreutils}/bin/env usr/bin/env
      ln -s ${orcaCli}/bin/orca-ide usr/bin/orca-ide
      # The CLI only renders Compose files; stacks run through sandbox-runner on the host engine.
      mkdir -p usr/libexec/docker/cli-plugins
      ln -s ${docker-compose}/libexec/docker/cli-plugins/docker-compose usr/libexec/docker/cli-plugins/docker-compose
      # For prebuilt binaries uploaded over SSH.
      ln -s ${nix-ld}/libexec/nix-ld lib64/ld-linux-x86-64.so.2
      ln -s ${nixConf} etc/nix/nix.conf
      ln -s ${fontconfig.out}/etc/fonts/conf.d etc/fonts/conf.d
      ln -s ${tzdata}/share/zoneinfo etc/zoneinfo
      # Steam's bundled libcurl ignores SSL_CERT_FILE and reads Debian's bundle path.
      ln -s ${caBundle} etc/ssl/certs/ca-bundle.crt
      ln -s ${caBundle} etc/ssl/certs/ca-certificates.crt
      mkdir -p etc/ssh
      ln -s ${./ssh_config} etc/ssh/ssh_config
      ln -s ${./sway.conf} etc/sway/config
      ln -s ${./nested-sway.conf} etc/sway/nested
      ln -s ${./pipewire.conf} etc/pipewire/pipewire.conf.d/50-agent-sandbox.conf
      ln -s ${./wireplumber.conf} etc/wireplumber/wireplumber.conf.d/50-agent-sandbox.conf
      ln -s ${instructions} etc/claude-code/CLAUDE.md
      ln -s ${claudeManagedSettings} etc/claude-code/managed-settings.json
      ln -s ${opencodeSystemConfig} etc/opencode/opencode.json
      echo 'hosts: files dns' > etc/nsswitch.conf
    '';
    config = {
      Entrypoint = [ (lib.getExe entrypoint) ];
      Cmd = [
        "claude"
        "--dangerously-skip-permissions"
      ];
      Env = lib.mapAttrsToList (name: value: "${name}=${value}") {
        PATH = "${env}/bin:/usr/bin";
        LANG = "C.UTF-8";
        CLAUDE_CODE_SANDBOXED = "1";
        # Claude Code reads these only from its launch environment. They drop the rm prompts it
        # can skip; removing the working directory, its parents or $HOME still prompts.
        CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT = "1";
        CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT = "1";
        CLAUDE_CODE_DISABLE_MOUNTED_DRIVE_RM_PROMPT = "1";
        ORCA_CLI_COMMAND = "orca-ide";
        GI_TYPELIB_PATH = lib.makeSearchPath "lib/girepository-1.0" [
          at-spi2-core
          gobject-introspection
        ];
        LOCALE_ARCHIVE = "${glibcLocales}/lib/locale/locale-archive";
        # As on NixOS: the host's /etc/localtime is mounted, and a TZ that names a zone resolves
        # through TZDIR for glibc and /etc/zoneinfo for readers that ignore TZDIR, such as chrono.
        TZDIR = "/etc/zoneinfo";
        SSL_CERT_FILE = caBundle;
        NIX_SSL_CERT_FILE = caBundle;
        FONTCONFIG_FILE = "${makeFontsConf {
          fontDirectories = [
            dejavu_fonts
            liberation_ttf
          ];
        }}";
        NIX_REMOTE = "daemon";
        NIX_LD = "${glibc}/lib/ld-linux-x86-64.so.2";
        NIX_LD_LIBRARY_PATH = nixLdLibraryPath;
        NIX_PATH = "nixpkgs=${path}";
        # python-build-standalone runs through nix-ld, so its wheels load; a Nix Python's venv
        # cannot find libstdc++.
        UV_PYTHON_PREFERENCE = "only-managed";
        UNREAL_MCP_URL = unrealMcp.url;
        DISABLE_AUTOUPDATER = "1";
        DBUS_SESSION_BUS_CONFIG = "${dbus}/share/dbus-1/session.conf";
        WLR_BACKENDS = "headless";
        WLR_HEADLESS_OUTPUTS = "1";
        WLR_LIBINPUT_NO_DEVICES = "1";
        XDG_SESSION_TYPE = "wayland";
        WAYLAND_DISPLAY = "wayland-1";
        MOZ_ENABLE_WAYLAND = "1";
        NIXOS_OZONE_WL = "1";
        PLAYWRIGHT_BROWSERS_PATH = "${playwright-browsers}";
        PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
        NODE_PATH = playwrightNodePath;
        GST_PLUGIN_SYSTEM_PATH_1_0 = gstPluginSystemPath;
        CARGO_PROFILE_DEV_DEBUG = "line-tables-only";
        CARGO_PROFILE_TEST_DEBUG = "line-tables-only";
        CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS = "-C link-arg=-fuse-ld=mold";
        # The cache lands in the sandboxes' shared home, never the host's: a sandbox must not
        # write objects the host links. Each container runs its own server, so each enforces
        # the size cap on its own.
        RUSTC_WRAPPER = "sccache";
        SCCACHE_CACHE_SIZE = "30G";
      };
    };
  };

  imageEnv = {
    AGENT_SANDBOX_IMAGE = image;
    # Prefix numeric-leading tags so ShellCheck does not mistake the generated
    # environment assignment for arithmetic (SC2100).
    AGENT_SANDBOX_TAG = "hash-${image.imageTag}";
  };

  launcher = writeShellApplication {
    name = "agent-sandbox";
    runtimeInputs = [
      coreutils
      getent
      gnugrep
      gnused
      iproute2
      jq
      openssh
      procps
      socat
      systemd
      util-linux
    ];
    runtimeEnv = imageEnv // {
      AGENT_SANDBOX_EGRESS_LIB = "${./egress.sh}";
      AGENT_SANDBOX_EGRESS_ENV = egressEnv;
      # The PATH an agent with an Orca hook bridge runs with: the curl shim leads,
      # so hook URLs route through the private relay socket.
      AGENT_SANDBOX_ORCA_PATH = "${orcaCurl}/bin:${env}/bin:/usr/bin";
      # Claude reads these from the image; agy reads them as its global AGENTS.md.
      AGENT_SANDBOX_INSTRUCTIONS = "${instructions}";
      AGENT_SANDBOX_ORCA_RELAY = lib.getExe orcaRelay;
      AGENT_SANDBOX_RUNNER = lib.getExe runner;
      AGENT_SANDBOX_SECCOMP = "${seccompProfile}";
    };
    text = builtins.readFile ./agent-sandbox.sh;
  };

  codexServer = writeShellApplication {
    name = "agent-sandbox-codex-server";
    runtimeInputs = [
      coreutils
      findutils
      getent
      jq
      socat
    ];
    runtimeEnv = imageEnv // {
      AGENT_SANDBOX_CODEX_SERVER_ENTRYPOINT = lib.getExe codexServerEntrypoint;
      AGENT_SANDBOX_CODEX_REQUIREMENTS = "${codexRequirements}";
      AGENT_SANDBOX_EGRESS_LIB = "${./egress.sh}";
      AGENT_SANDBOX_EGRESS_ENV = egressEnv;
    };
    text = builtins.readFile ./agent-sandbox-codex-server.sh;
  };

  sshProxy = writeShellApplication {
    name = "agent-sandbox-ssh";
    runtimeInputs = [
      coreutils
      systemd
    ];
    runtimeEnv.AGENT_SANDBOX_SSHD = lib.getExe' openssh "sshd";
    text = builtins.readFile ./agent-sandbox-ssh.sh;
  };

  clean = writeShellApplication {
    name = "agent-sandbox-clean";
    runtimeInputs = [
      coreutils
      findutils
      gnugrep
      systemd
    ];
    text = builtins.readFile ./agent-sandbox-clean.sh;
  };

  killAll = writeShellApplication {
    name = "agent-sandbox-kill";
    runtimeInputs = [
      clean
      coreutils
      procps
      systemd
    ];
    text = builtins.readFile ./agent-sandbox-kill.sh;
  };

  botHome = writeShellApplication {
    name = "agent-sandbox-bot-home";
    runtimeInputs = [ coreutils ];
    text = builtins.readFile ./agent-sandbox-bot-home.sh;
  };

  execAgent = writeShellApplication {
    name = "agent-sandbox-exec";
    runtimeInputs = [
      botHome
      coreutils
      git
    ];
    runtimeEnv = {
      AGENT_SANDBOX_HOOK_PROXY = lib.getExe hookProxy;
      AGENT_SANDBOX_PREPARE_ORCA_HOOKS = lib.getExe prepareOrcaHooks;
      AGENT_SANDBOX_LAUNCHER = lib.getExe launcher;
    };
    text = builtins.readFile ./agent-sandbox-exec.sh;
  };

  resumeAgent = writeShellApplication {
    name = "agent-sandbox-resume";
    runtimeInputs = [
      botHome
      execAgent
      git
      jq
    ];
    runtimeEnv.AGENT_SANDBOX_HOST_BOT_IDS = lib.concatStringsSep " " (import ./host-bots.nix);
    text = builtins.readFile ./agent-sandbox-resume.sh;
  };
in
symlinkJoin {
  name = "agent-sandbox";
  passthru = {
    imageRef = "agent-sandbox:${image.imageTag}";
    inherit image seccompProfile;
    smoke = sandboxSmoke;
    rootGuardTests =
      runCommand "agent-sandbox-root-guard-tests"
        {
          nativeBuildInputs = [
            bashInteractive
            python3
          ];
        }
        ''
          python3 -B ${./test-root-guard.py} ${./.} -v
          touch $out
        '';
    runnerTests =
      runCommand "agent-sandbox-runner-tests"
        {
          nativeBuildInputs = [
            git
            python3
            socat
          ];
        }
        ''
          cp ${./runner/runner.py} runner.py
          cp ${./runner/test-runner.py} test-runner.py
          python3 -B test-runner.py -v
          touch $out
        '';
    launcherTests =
      runCommand "agent-sandbox-launcher-tests"
        {
          nativeBuildInputs = [
            bashInteractive
            git
            gnused
            procps
            python3
            util-linux
          ];
        }
        ''
          cp ${./agent-sandbox.sh} agent-sandbox.sh
          cp ${./test-launcher-mounts.py} test-launcher-mounts.py
          python3 -B test-launcher-mounts.py -v
          touch $out
        '';
    unrealTools = unreal.tools;
    unrealTests = unreal.tests;
    displayTests =
      runCommand "sandbox-display-tests"
        {
          nativeBuildInputs = [
            bashInteractive
            python3
            util-linux
          ];
        }
        ''
          cp ${./sandbox-display.sh} sandbox-display.sh
          cp ${./test-sandbox-display.py} test-sandbox-display.py
          python3 -B test-sandbox-display.py -v
          touch $out
        '';
    orcaTests =
      runCommand "agent-sandbox-orca-tests"
        {
          nativeBuildInputs = [ python3 ];
        }
        ''
          cp ${./hook-proxy.py} hook-proxy.py
          cp ${./orca-relay.py} orca-relay.py
          cp ${./test-hook-proxy.py} test-hook-proxy.py
          cp ${./test-orca-relay.py} test-orca-relay.py
          python3 -B test-hook-proxy.py -v
          python3 -B test-orca-relay.py -v
          touch $out
        '';
    execTests =
      runCommand "agent-sandbox-exec-tests"
        {
          nativeBuildInputs = [
            bashInteractive
            git
            jq
            python3
          ];
        }
        ''
          cp ${./agent-sandbox-bot-home.sh} agent-sandbox-bot-home.sh
          cp ${./agent-sandbox-exec.sh} agent-sandbox-exec.sh
          cp ${./agent-sandbox-resume.sh} agent-sandbox-resume.sh
          cp ${./test-agent-sandbox-exec.py} test-agent-sandbox-exec.py
          python3 -B test-agent-sandbox-exec.py -v
          touch $out
        '';
    launcherOpencodeTests =
      runCommand "agent-sandbox-launcher-opencode-tests"
        {
          nativeBuildInputs = [
            bashInteractive
            coreutils
            jq
            python3
            util-linux
          ];
        }
        ''
          cp ${./agent-sandbox.sh} agent-sandbox.sh
          cp ${./egress.sh} egress.sh
          cp ${./test-launcher-opencode.py} test-launcher-opencode.py
          python3 -B test-launcher-opencode.py -v
          touch $out
        '';
    codexTests =
      runCommand "agent-sandbox-codex-tests"
        {
          nativeBuildInputs = [
            bashInteractive
            python3
          ];
        }
        ''
          cp ${./codex.sh} codex.sh
          cp ${./test-codex.py} test-codex.py
          python3 -B test-codex.py -v
          touch $out
        '';
  };
  paths = [
    launcher
    codexServer
    execAgent
    resumeAgent
    unreal.installer
    clean
    killAll
    sshProxy
  ];
  meta = {
    description = "Run Claude Code, Codex, Antigravity or OpenCode in a Docker sandbox with the GPU and a headless Wayland session";
    mainProgram = "agent-sandbox";
    platforms = [ "x86_64-linux" ];
  };
}
