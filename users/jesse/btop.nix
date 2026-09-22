_: {
  programs.btop = {
    enable = true;
    settings = {
      show_disks = false;
      vim_keys = true;
    };
  };

  catppuccin.btop = {
    enable = true;
    flavor = "mocha";
  };
}
