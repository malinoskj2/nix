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

  unwrapped = runCommand "muse-unwrapped-${version}" { } ''
    install -Dm755 ${
      fetchurl {
        url = "https://lookaside.facebook.com/lookaside/muse/download/?channel=muse&version=${version}&file=${artifact.file}";
        inherit (artifact) hash;
      }
    } $out/bin/.muse-unwrapped
  '';
in
(writeShellApplication {
  name = "muse";
  runtimeEnv = {
    MUSE_UNWRAPPED_BIN = "${unwrapped}/bin/.muse-unwrapped";
    MUSE_CONTRIBUTOR_MODEL = contributorModel;
  };
  text = ''
    if [[ -n ''${MUSE_MODEL:-} ]]; then
      exec "$MUSE_UNWRAPPED_BIN" "$@"
    fi
    for arg in "$@"; do
      if [[ $arg == --model || $arg == --model=* ]]; then
        exec "$MUSE_UNWRAPPED_BIN" "$@"
      fi
    done
    exec "$MUSE_UNWRAPPED_BIN" --model "$MUSE_CONTRIBUTOR_MODEL" "$@"
  '';
}).overrideAttrs
  {
    meta = {
      description = "Meta's Muse Code terminal coding agent, starting in contributor mode by default";
      mainProgram = "muse";
      platforms = lib.platforms.linux;
    };
  }
