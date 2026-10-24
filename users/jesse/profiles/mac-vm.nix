{
  imports = [
    ../global

    ../features/admin.nix
    ../features/cli.nix
    ../features/desktop.nix
    ../features/dev.nix
    ../features/native.nix
    ../features/rust

    ../datagrip
    ../git.nix
    ../hyprland-desktop
  ];

  # Fusion's "Use All Displays in Full Screen" gives each Mac display a Virtual-N output.
  desktop.monitors = {
    main = {
      output = "Virtual-1";
      position = "0x0";
    };
    side = {
      output = "Virtual-2";
      position = "auto-right";
    };
  };

  home.stateVersion = "26.05";
}
