{
  programs.mpv = {
    enable = true;
    config = {
      profile = "opengl-hq";
      scale = "ewa_lanczossharp";
      cscale = "ewa_lanczossharp";
      video-sync = "display-resample";
      interpolation = true;
      tscale = "oversample";
      x11-bypass-compositor = true;
      shuffle = true;
      loop-playlist = true;

      vo = "gpu";
      hwdec = "nvdec";
      hwdec-codecs = "all";

      ytdl-format = "bestvideo[height<=?1080]+bestaudio/best";

      tone-mapping = "hable";
      tone-mapping-desaturate = "0.0";
      target-prim = "auto";
      target-trc = "auto";
      hdr-compute-peak = true;
      autosync = 30;

      osd-font = "Fira Mono";
      sub-font = "Lato";
    };
  };
}
