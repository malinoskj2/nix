# Package
{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    vim
    git
    htop-vim
    ripgrep
    fd
    tmux
    curl
    dnsutils
    lazydocker
    docker-compose
    smartmontools
    iperf
    speedtest-cli
  ];
}
