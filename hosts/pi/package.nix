# Package
{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    vim
    htop-vim-navigation
    ripgrep
    git
    docker-compose
    hdparm
    usbutils
    idle3tools
    fd
    speedtest-cli
    iperf
    nixfmt
  ];
}
