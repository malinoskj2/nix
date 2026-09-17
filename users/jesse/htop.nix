{ config, pkgs, ... }:

let
  inherit (config.lib.htop)
    leftMeters
    rightMeters
    bar
    text
    ;
in
{
  programs.htop = {
    enable = true;
    package = pkgs.htop-vim-navigation;

    settings = {
      # Home Manager always writes a legacy `fields` key; format v3 makes htop
      # ignore it and keep its default Main and I/O screens.
      config_reader_min_version = 3;
      screen_tabs = true;
    }
    // leftMeters [
      (bar "LeftCPUs4")
      (bar "Memory")
      (bar "Swap")
    ]
    // rightMeters [
      (bar "RightCPUs4")
      (text "Tasks")
      (text "LoadAverage")
      (text "Uptime")
    ];
  };
}
