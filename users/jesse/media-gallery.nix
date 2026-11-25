{ lib, pkgs, ... }:
{
  home.packages = [ pkgs.media-gallery ];

  # Agents publish galleries to this hub, so their links outlive the agent and its sandbox.
  systemd.user.services.media-gallery = {
    Unit.Description = "Media gallery hub";
    Service = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.media-gallery)
        "hub"
        "--port"
        "8070"
        "--discover"
        "%h/projects"
        "%h/orca/workspaces"
        "%h/nix"
        "%h/.orca/bots"
      ];
      Restart = "always";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
