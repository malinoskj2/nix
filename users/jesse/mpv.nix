{
  programs.mpv = {
    enable = true;
    defaultProfiles = [ "high-quality" ];
    config = {
      hdr-compute-peak = true;
      hwdec = "auto-safe";
      interpolation = true;
      loop-playlist = true;
      osd-font = "Fira Mono";
      shuffle = true;
      sub-font = "Lato";
      tone-mapping = "hable";
      video-sync = "display-resample";
      ytdl-format = "bestvideo[height<=?1080]+bestaudio/best";
    };
  };
}
