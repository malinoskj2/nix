# Media library disks, with trees moved off /media bound back so container
# paths stay unchanged.
let
  disk = uuid: {
    device = "/dev/disk/by-uuid/${uuid}";
    fsType = "ext4";
    options = [
      "noatime"
      "nofail"
    ];
  };

  bind = device: {
    inherit device;
    fsType = "auto";
    options = [
      "bind"
      "nofail"
    ];
  };
in
{
  fileSystems = {
    "/media" = disk "bc8f4323-b847-43ee-8869-b1011acdddeb";
    "/mnt/media2" = disk "aef389ef-b875-434d-8a92-327e341c0bba";
    "/mnt/media3" = disk "da01f4dd-a667-4b50-9558-5a60e3015f0a";
    "/mnt/media4" = disk "8eb80012-a38b-4b82-9c63-eb0e17cfb490";

    "/media/storage/media/tv_cartoon" = bind "/mnt/media2/tv_cartoon";
    "/media/storage/media/tv" = bind "/mnt/media2/tv";
    "/media/storage/media/legacy_media" = bind "/mnt/media2/legacy_media";
    "/media/storage/media/movies" = bind "/mnt/media3/movies";
  };
}
