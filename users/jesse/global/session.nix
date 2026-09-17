# Session environment shared by every profile.
{
  home = {
    language = {
      base = "en_US.UTF-8";
      time = "en_US.UTF-8";
    };

    sessionVariables = {
      PAGER = "less -R";
      TERMINAL = "alacritty";
      CHARSET = "UTF-8";
      LS_COLORS = "di=34:ex=35";
      SSH_ASKPASS_REQUIRE = "never";
      LIBGIT2_SYS_USE_PKG_CONFIG = "1";
    };

    sessionPath = [
      "$HOME/.cargo/bin"
      "$HOME/.local/bin"
    ];
  };
}
