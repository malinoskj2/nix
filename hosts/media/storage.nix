{ ... }:

{
  fileSystems = {
    "/media" = {
      device = "/dev/disk/by-uuid/bc8f4323-b847-43ee-8869-b1011acdddeb";
      fsType = "ext4";
      options = [
        "noatime"
        "nofail"
      ];
    };

    "/mnt/media2" = {
      device = "/dev/disk/by-uuid/aef389ef-b875-434d-8a92-327e341c0bba";
      fsType = "ext4";
      options = [
        "noatime"
        "nofail"
      ];
    };

    "/mnt/media3" = {
      device = "/dev/disk/by-uuid/da01f4dd-a667-4b50-9558-5a60e3015f0a";
      fsType = "ext4";
      options = [
        "noatime"
        "nofail"
      ];
    };

    # 2.7TB WD (WD30EZRZ). Holds a relocated slice of the media library,
    # consumed directly by the Plex and qBittorrent containers via
    # pi-media-stack/docker-compose.yml.
    "/mnt/media4" = {
      device = "/dev/disk/by-uuid/8eb80012-a38b-4b82-9c63-eb0e17cfb490";
      fsType = "ext4";
      options = [
        "noatime"
        "nofail"
      ];
    };

    "/media/storage/media/tv_cartoon" = {
      device = "/mnt/media2/tv_cartoon";
      fsType = "auto";
      options = [
        "bind"
        "nofail"
      ];
    };
    "/media/storage/media/tv" = {
      device = "/mnt/media2/tv";
      fsType = "auto";
      options = [
        "bind"
        "nofail"
      ];
    };
    "/media/storage/media/legacy_media" = {
      device = "/mnt/media2/legacy_media";
      fsType = "auto";
      options = [
        "bind"
        "nofail"
      ];
    };
    "/media/storage/media/movies" = {
      device = "/mnt/media3/movies";
      fsType = "auto";
      options = [
        "bind"
        "nofail"
      ];
    };
  };
}
