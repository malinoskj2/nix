{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    btop
    htop-vim-navigation

    fd
    iperf
    ripgrep
    ookla-speedtest
  ];
}
