# X11
{ config, pkgs, lib, ... }: {
  services.xserver = {
    enable = true;
    autorun = false;
    xkb.layout = "us";
    autoRepeatDelay = 260;
    autoRepeatInterval = 18;
    displayManager.startx.enable = true;
    windowManager.bspwm.enable = true;
    windowManager.bspwm.configFile = "/home/jesse/env/config/bspwm/bspwmrc";
    windowManager.bspwm.sxhkd.configFile =
      "/home/jesse/env/config/sxhkd/sxhkdrc";
  };
}

