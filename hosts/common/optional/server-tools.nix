# CLI tools for administering a headless host over SSH.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    fd
    htop-vim-navigation
    iperf
    ripgrep
    speedtest-cli
  ];
}
