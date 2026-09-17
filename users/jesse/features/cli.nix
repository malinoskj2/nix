{ pkgs, ... }:
{
  home.packages = with pkgs; [
    ai-usage
    git-commitu
    git-open-branch
    pubip

    bc
    envsubst
    eza
    fd
    file
    gnupg
    jq
    neovim
    nmap
    nssTools
    p7zip
    pandoc
    ripgrep
    tldr
    tokei
    tree
    unrar
    whois
    zip
  ];
}
