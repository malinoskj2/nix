# Package
{ pkgs, ... }:

{
  nix.extraOptions = "experimental-features = nix-command flakes";
  nixpkgs.config.allowUnfree = true;

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
