{
  ffmpeg,
  gst_all_1,
  lib,
  playwright-driver,
  runCommand,
}:

let
  # WebKit's MiniBrowser links GStreamer but finds no plugins without a system path. Its own
  # inputs give the core, base and bad plugins; good and libav come from the same GStreamer set.
  webkitGst = lib.filter (
    p: lib.hasPrefix "gst" (p.pname or "")
  ) playwright-driver.components.webkit.buildInputs;
  webkitGstreamer = lib.findFirst (
    p: p.pname == "gstreamer"
  ) (throw "WebKit links no GStreamer") webkitGst;
  gstPlugins =
    assert lib.assertMsg (
      webkitGstreamer.drvPath == gst_all_1.gstreamer.drvPath
    ) "playwright-browsers: WebKit links a different GStreamer from gst_all_1";
    webkitGst
    ++ [
      gst_all_1.gst-plugins-good
      gst_all_1.gst-libav
    ];
in
# A project's own Playwright records video only with the ffmpeg at
# ffmpeg-<its revision>/ffmpeg-linux here, and nixpkgs ships one revision.
# Other revisions get nixpkgs' ffmpeg, whose VP8, VP9 and Matroska support
# covers the arguments Playwright's own builds take.
runCommand "playwright-browsers"
  {
    passthru.gstPluginSystemPath = lib.makeSearchPath "lib/gstreamer-1.0" (map (p: p.out) gstPlugins);
    meta = {
      description = "nixpkgs' Playwright browsers, with an ffmpeg under every recent revision";
      platforms = lib.platforms.linux;
    };
  }
  ''
    mkdir $out
    ln -s ${playwright-driver.browsers}/* $out/
    for revision in $(seq 1000 1099); do
      if [[ ! -e $out/ffmpeg-$revision ]]; then
        mkdir $out/ffmpeg-$revision
        ln -s ${lib.getExe ffmpeg} $out/ffmpeg-$revision/ffmpeg-linux
      fi
    done
  ''
