# Package
{ pkgs, ... }:

{
  nix = { extraOptions = "experimental-features = nix-command flakes"; };
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    vim
    htop-vim
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
