# CLI tools for administering a headless host over SSH.
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
