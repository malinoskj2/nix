{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    htop-vim-navigation

    fd
    iperf
    ripgrep
    speedtest-cli
  ];
}
