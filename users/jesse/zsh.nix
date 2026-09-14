{
  programs.zsh = {
    enable = true;
    initContent = builtins.readFile /home/jesse/env/zsh/zshrc;
  };
}
