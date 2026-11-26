{
  coreutils,
  curl,
  fzf,
  gawk,
  gnugrep,
  gnused,
  jq,
  lib,
  runCommand,
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
  passthru.tests.stubs =
    runCommand "media-web-tests"
      {
        nativeBuildInputs = [
          coreutils
          gawk
          gnugrep
          gnused
          jq
        ];
      }
      ''
        bash ${./.}/test.sh
        touch "$out"
      '';
  meta = {
    description = "Find the media host's web UIs and open them in Firefox";
    platforms = lib.platforms.linux;
  };
}
