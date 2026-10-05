{
  coreutils,
  drm_info,
  gawk,
  gnugrep,
  hyprland,
  jq,
  lib,
  makeWrapper,
  procps,
  shellcheck,
  stdenvNoCC,
  systemd,
  util-linux,
  xrandr,
}:

stdenvNoCC.mkDerivation {
  pname = "game-latency-check";
  version = "1.0";
  src = ./.;
  nativeBuildInputs = [
    makeWrapper
    shellcheck
  ];
  nativeCheckInputs = [
    coreutils
    gawk
    gnugrep
    jq
  ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    shellcheck game-latency-check.sh tests/test-diagnostics.sh
    bash tests/test-diagnostics.sh
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 game-latency-check.sh "$out/bin/game-latency-check"
    patchShebangs "$out/bin/game-latency-check"
    wrapProgram "$out/bin/game-latency-check" \
      --prefix PATH : ${
        lib.makeBinPath [
          coreutils
          drm_info
          gawk
          gnugrep
          hyprland
          jq
          procps
          systemd
          util-linux
          xrandr
        ]
      } \
      --set GAME_LATENCY_FILTER ${./presentation.jq}
    runHook postInstall
  '';
  meta = {
    description = "Read-only Hyprland and Linux latency diagnostics for running games";
    mainProgram = "game-latency-check";
    platforms = lib.platforms.linux;
  };
}
