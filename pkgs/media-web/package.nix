{
  coreutils,
  curl,
  fzf,
  gawk,
  gnugrep,
  gnused,
  jq,
  lib,
  openssh,
  writeShellApplication,
}:

writeShellApplication {
  name = "media-web";
  runtimeInputs = [
    coreutils
    curl
    fzf
    gawk
    gnugrep
    gnused
    jq
    openssh
  ];
  runtimeEnv = {
    MEDIA_WEB_DISCOVER = ./discover.sh;
    MEDIA_WEB_PROBE = ./probe.sh;
  };
  text = builtins.readFile ./media-web.sh;
  meta = {
    description = "Find the media host's web UIs and open them in Firefox";
    platforms = lib.platforms.linux;
  };
}
