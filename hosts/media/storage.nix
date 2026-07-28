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

    # 2.7TB WD (WD30EZRZ), ext4 label "anime". Holds the relocated slice of the
    # anime library; consumed directly by the containers (plex /anime4,
    # qbittorrent /downloads/anime4) via pi-media-stack/docker-compose.yml.
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
      options = [
        "bind"
        "nofail"
      ];
    };
    "/media/storage/media/tv" = {
      device = "/mnt/media2/tv";
      options = [
        "bind"
        "nofail"
      ];
    };
    "/media/storage/media/anime_ova" = {
      device = "/mnt/media2/anime_ova";
      options = [
        "bind"
        "nofail"
      ];
    };
    "/media/storage/media/movies" = {
      device = "/mnt/media3/movies";
      options = [
        "bind"
        "nofail"
      ];
    };
  };
}
