# X11
_: {
  services.xserver = {
    enable = true;
    autorun = false;
    xkb.layout = "us";
    autoRepeatDelay = 260;
    autoRepeatInterval = 18;
    displayManager.startx.enable = true;
    windowManager.bspwm = {
      enable = true;
      configFile = "/home/jesse/env/config/bspwm/bspwmrc";
      sxhkd.configFile = "/home/jesse/env/config/sxhkd/sxhkdrc";
    };
  };
}
