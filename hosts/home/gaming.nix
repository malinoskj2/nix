{ lib, pkgs, ... }:
let
  steamGameMode =
    p:
    assert lib.assertMsg (
      p.gamemode.version == "1.8.2"
    ) "The Steam GameMode patch requires review for GameMode ${p.gamemode.version}.";
    p.gamemode.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./steam-gamemode.patch ];
      # The auto loader dlopens the client by soname. Steam's inner runtime
      # replaces LD_LIBRARY_PATH, so the client also needs an explicit search path.
      postFixup = (old.postFixup or "") + ''
        patchelf --add-rpath "$lib/lib" "$lib/lib/libgamemodeauto.so.0.0.0"
      '';
    });
  # Pressure-vessel rewrites sonames to /run/host/lib, whose /usr symlink points
  # into the inner runtime. Store paths remain accessible in both containers.
  steamGameModePreload = pkgs.linkFarm "steam-gamemode-preload" [
    {
      name = "x86_64/libgamemodeauto.so.0";
      path = "${lib.getLib (steamGameMode pkgs)}/lib/libgamemodeauto.so.0";
    }
    {
      name = "i686/libgamemodeauto.so.0";
      path = "${lib.getLib (steamGameMode pkgs.pkgsi686Linux)}/lib/libgamemodeauto.so.0";
    }
  ];

in
{
  environment.systemPackages = [
    pkgs.game-background-limit
    pkgs.game-latency-check
  ];

  nixpkgs.overlays = [
    (_final: prev: {
      gamemode =
        assert lib.assertMsg (
          prev.gamemode.version == "1.8.2"
        ) "The I/O priority patch requires review for GameMode ${prev.gamemode.version}.";
        prev.gamemode.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./gamemode-ioprio.patch ];
        });
    })
  ];

  # GameMode's privileged CPU policy helpers require membership in this group.
  users.users.jesse.extraGroups = [ "gamemode" ];

  # ExecStart uses a stable security-wrapper path; changing its target alone
  # does not make systemd notice that the running user daemon needs replacing.
  systemd.user.services.gamemoded.restartTriggers = [ pkgs.gamemode ];
  systemd.user.services.game-background-limit = {
    description = "Limit unfocused Steam games to 10 FPS";
    after = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.game-background-limit} --daemon";
      Restart = "on-failure";
      RestartSec = 1;
    };
  };

  programs = {
    # Check tearing eligibility before the first frame has been marked torn.
    # Keep this on the physical desktop; nested agent compositors do not use DRM.
    hyprland.package =
      assert lib.assertMsg (
        pkgs.hyprland.version == "0.56.2"
      ) "The tearing patch requires review for Hyprland ${pkgs.hyprland.version}.";
      pkgs.hyprland.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./tearing-first-frame.patch ];
      });
    gamemode = {
      enable = true;
      # CCD0 has 96 MiB L3 (V-Cache); include its SMT siblings. Pin only
      # registered games and keep both CCDs online for the unrestricted desktop.
      settings.cpu = {
        pin_cores = "0-7,16-23";
        park_cores = "no";
      };
      # Steam inherits the automatic client library, but its persistent UI must
      # not keep GameMode active after the last game exits. Filters are path
      # substrings, so avoid "steam" (which also appears in game install paths).
      settings.filter.blacklist = [
        "/ubuntu12_32/steam"
        "/steamwebhelper"
        "/steamservice"
        "/steam_monitor"
        "/steam-runtime-launcher-service"
        "-srt-launcher-service"
        "/steam-runtime-supervisor"
        "/steam-runtime-input-monitor"
        "/srt-logger"
      ];
    };
    steam = {
      enable = true;
      package = pkgs.steam.override {
        # Every Steam game inherits the standalone presentation limiter.
        # Its guard leaves Steam UI/helpers and opted-out games uncapped.
        extraPkgs = p: [ p.game-background-limit ];
        # The preload library must stay inactive in Steam's startup tools.
        # Build the same game-ID and fork guards for both library architectures.
        extraLibraries = p: [
          (lib.getLib (steamGameMode p))
          p.game-background-engine
        ];
        extraProfile = ''
          export GAME_BACKGROUND_LIMIT_AUTO=1 GAME_BACKGROUND_VULKAN=1
          export XDG_DATA_DIRS='${pkgs.game-background-limit}/share'"''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
          export LD_PRELOAD='${steamGameModePreload}/''${PLATFORM}/libgamemodeauto.so.0:${pkgs.game-background-limit}/preload/''${PLATFORM}/libgame-background.so'"''${LD_PRELOAD:+:$LD_PRELOAD}"
        '';
      };
    };
  };
}
