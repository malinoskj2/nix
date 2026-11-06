{
  ffmpeg,
  lib,
  playwright-driver,
  runCommand,
}:

# A project's own Playwright records video only with the ffmpeg at
# ffmpeg-<its revision>/ffmpeg-linux here, and nixpkgs ships one revision.
# Other revisions get nixpkgs' ffmpeg, whose VP8, VP9 and Matroska support
# covers the arguments Playwright's own builds take.
runCommand "playwright-browsers"
  {
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
