{ pkgs, ... }:
let
  mkDisk = uuid: {
    device = "/dev/disk/by-uuid/${uuid}";
    fsType = "ext4";
    options = [
      "noatime"
      "nofail"
    ];
  };
  mkBind = device: {
    inherit device;
    fsType = "auto";
    options = [
      "bind"
      "nofail"
    ];
  };
in
{
  systemd.services.models-directory = {
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      RequiresMountsFor = [ "/media" ];
      ConditionPathIsMountPoint = "/media";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/install -d -m 0755 -o jesse -g users /media/models";
    };
  };

  systemd.services.agent-share-directory = {
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      RequiresMountsFor = [ "/mnt/media3" ];
      ConditionPathIsMountPoint = "/mnt/media3";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/install -d -m 0755 -o jesse -g users /mnt/media3/agent-share";
    };
  };

  fileSystems = {
    "/media" = mkDisk "bc8f4323-b847-43ee-8869-b1011acdddeb";
    "/mnt/media2" = mkDisk "aef389ef-b875-434d-8a92-327e341c0bba";
    "/mnt/media3" = mkDisk "da01f4dd-a667-4b50-9558-5a60e3015f0a";
    "/mnt/media4" = mkDisk "8eb80012-a38b-4b82-9c63-eb0e17cfb490";

    # Keep legacy paths stable while their data lives on the appropriate disks.
    "/media/storage/media/legacy_media" = mkBind "/mnt/media2/legacy_media";
    "/media/storage/media/movies" = mkBind "/media/data/media/movies";
    "/media/storage/media/tv" = mkBind "/mnt/media2/tv";
    "/media/storage/media/tv_cartoon" = mkBind "/mnt/media2/tv_cartoon";
  };
}
