# Trees moved off /media are bound back so container paths stay unchanged.
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
  fileSystems = {
    "/media" = mkDisk "bc8f4323-b847-43ee-8869-b1011acdddeb";
    "/mnt/media2" = mkDisk "aef389ef-b875-434d-8a92-327e341c0bba";
    "/mnt/media3" = mkDisk "da01f4dd-a667-4b50-9558-5a60e3015f0a";
    "/mnt/media4" = mkDisk "8eb80012-a38b-4b82-9c63-eb0e17cfb490";

    "/media/storage/media/legacy_media" = mkBind "/mnt/media2/legacy_media";
    "/media/storage/media/movies" = mkBind "/mnt/media3/movies";
    "/media/storage/media/tv" = mkBind "/mnt/media2/tv";
    "/media/storage/media/tv_cartoon" = mkBind "/mnt/media2/tv_cartoon";
  };
}
