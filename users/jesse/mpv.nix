{
  programs.mpv = {
    enable = true;
    defaultProfiles = [ "high-quality" ];
    config = {
      video-sync = "display-resample";
      interpolation = true;
      shuffle = true;
      loop-playlist = true;

      hwdec = "nvdec";
      hwdec-codecs = "all";

      ytdl-format = "bestvideo[height<=?1080]+bestaudio/best";

      tone-mapping = "hable";
      hdr-compute-peak = true;

      osd-font = "Fira Mono";
      sub-font = "Lato";
    };
  };
}
