# Package
{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    vim
    git
    htop-vim-navigation
    ripgrep
    fd
    tmux
    curl
    dnsutils
    lazydocker
    smartmontools
    iperf
    speedtest-cli
  ];
}
