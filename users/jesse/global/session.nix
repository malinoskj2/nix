{
  home = {
    language = {
      base = "en_US.UTF-8";
      time = "en_US.UTF-8";
    };
    sessionVariables = {
      CHARSET = "UTF-8";
      LS_COLORS = "di=34:ex=35";
      PAGER = "less -R";
      # Interactive shells also unset SSH_ASKPASS and GIT_ASKPASS; see users/jesse/zsh.nix.
      SSH_ASKPASS_REQUIRE = "never";
      TERMINAL = "alacritty";
    };
    sessionPath = [
      "$HOME/.cargo/bin"
      "$HOME/.local/bin"
    ];
  };
}
