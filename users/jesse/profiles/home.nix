{ config, ... }:
{
  imports = [
    ../global

    ../features/admin.nix
    ../features/cli.nix
    ../features/desktop.nix
    ../features/discord-context.nix
    ../features/dev.nix
    ../features/local-models.nix
    ../features/native.nix
    ../features/rust
    ../features/rust/mold.nix

    ../agent-sandbox.nix
    ../datagrip
    ../git.nix
    ../opencode.nix
    ../hyprland-desktop
    ../target-sweep.nix
  ];

  # The side monitor stands portrait on the left, so the main monitor starts at its rotated width.
  desktop.monitors = {
    main = {
      output = "DP-2";
      mode = "1920x1080@360";
      position = "1080x0";
    };
    side = {
      output = "DP-1";
      mode = "1920x1080@144";
      position = "0x0";
      transform = 1;
    };
  };

  wallpaper.launcher.enable = true;

  services.local-models = {
    root = "/mnt/ext-ssd/models";
    stores = {
      external = "/mnt/ext-ssd/models";
      install = "${config.xdg.dataHome}/model-stores/install";
      media = "/mnt/media-models";
    };
    defaultStore = "external";
    mountedStores = [ "media" ];
    # The media host's drive also takes its media downloads.
    storeReserves.media = 1024;
  };

  services.discord-context.excludedGuilds = [
    "902708289098375209" # ogchat
  ];

  home.stateVersion = "25.11";
}
