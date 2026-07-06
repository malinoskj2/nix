{ ... }:

{
  fileSystems."/media" = {
    device = "/dev/disk/by-uuid/bc8f4323-b847-43ee-8869-b1011acdddeb";
    fsType = "ext4";
    options = [
      "noatime"
      "nofail"
    ];
  };

  fileSystems."/mnt/media2" = {
    device = "/dev/disk/by-uuid/aef389ef-b875-434d-8a92-327e341c0bba";
    fsType = "ext4";
    options = [
      "noatime"
      "nofail"
    ];
  };

  fileSystems."/mnt/media3" = {
    device = "/dev/disk/by-uuid/da01f4dd-a667-4b50-9558-5a60e3015f0a";
    fsType = "ext4";
    options = [
      "noatime"
      "nofail"
    ];
  };
  fileSystems."/media/storage/media/tv_cartoon" = {
    device = "/mnt/media2/tv_cartoon";
    options = [
      "bind"
      "nofail"
    ];
  };
  fileSystems."/media/storage/media/tv" = {
    device = "/mnt/media2/tv";
    options = [
      "bind"
      "nofail"
    ];
  };
  fileSystems."/media/storage/media/anime_ova" = {
    device = "/mnt/media2/anime_ova";
    options = [
      "bind"
      "nofail"
    ];
  };
  fileSystems."/media/storage/media/movies" = {
    device = "/mnt/media3/movies";
    options = [
      "bind"
      "nofail"
    ];
  };
}
