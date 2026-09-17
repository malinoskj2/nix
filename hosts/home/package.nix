# Package
{ pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    docker-compose
    libva-utils

    # Pulls in the full dotnet SDK, so keep it off the other hosts
    source2viewer-cli
  ];
}
