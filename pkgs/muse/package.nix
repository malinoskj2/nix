{
  fetchurl,
  lib,
  runCommand,
  stdenv,
  writeShellApplication,
}:
let
  # The channel endpoint (https://api.meta.ai/muse-code/channels/muse-stable)
  # names the current version and its manifest, which lists these artifacts.
  version = "1.4.2-R4684.1";

  # The contributor model is the discounted lane that trains on session data.
  # Muse starts there unless --model or MUSE_MODEL says otherwise.
  contributorModel = "muse-spark-1.3-contributor";

  artifact =
    {
      x86_64-linux = {
        file = "muse-x86-linux";
        hash = "sha256-37MJbJH0dnxNmABkYIALe6kGoLGkCCgKkmqNwZoa9k8=";
      };
      aarch64-linux = {
        file = "muse-aarch64-linux";
        hash = "sha256-+ml0wjMHoNXbkTZ1SeQVBaXntV3NZsZy6y3YnBoSWtY=";
      };
    }
    .${stdenv.hostPlatform.system};

  src = fetchurl {
    url = "https://lookaside.facebook.com/lookaside/muse/download/?channel=muse&version=${version}&file=${artifact.file}";
    inherit (artifact) hash;
  };

  unwrapped = runCommand "muse-unwrapped-${version}" { } ''
    install -Dm755 ${src} $out/bin/.muse-unwrapped
  '';
in
writeShellApplication {
  name = "muse";
  text = ''
    muse=${unwrapped}/bin/.muse-unwrapped
    if [[ -n ''${MUSE_MODEL:-} ]]; then
      exec "$muse" "$@"
    fi
    for arg in "$@"; do
      if [[ $arg == --model || $arg == --model=* ]]; then
        exec "$muse" "$@"
      fi
    done
    exec "$muse" --model ${contributorModel} "$@"
  '';
  meta = {
    description = "Meta's Muse Code terminal coding agent, starting in contributor mode by default";
    platforms = lib.platforms.linux;
  };
}
