{ pkgs, ... }:
{
  # Docker can try its restart policies before this nofail disk is mounted.
  # Recover only Skin Trader after the mount; other media services keep their
  # existing startup order. Container creation remains in skin-trader/deploy.sh.
  systemd.services.skin-trader-startup = {
    description = "Start deployed Skin Trader containers after the data disk";
    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" ];
    after = [ "docker.service" ];
    unitConfig = {
      RequiresMountsFor = [ "/mnt/media3" ];
      StartLimitIntervalSec = 0;
    };
    path = with pkgs; [
      coreutils
      docker
      util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStartSec = "12min";
    };
    script = builtins.readFile ./skin-trader-startup.sh;
  };
}
