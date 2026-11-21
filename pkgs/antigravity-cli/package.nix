{
  fetchurl,
  lib,
  makeBinaryWrapper,
  stdenv,
  symlinkJoin,
  unstable,
}:
let
  # https://storage.googleapis.com/antigravity-public/antigravity-cli/latest names the version,
  # and <version>/manifest.json its build and each platform's sha512.
  version = "1.5.14";
  build = "5302690847260672";

  artifact =
    {
      x86_64-linux = {
        path = "linux-x64/cli_linux_x64.tar.gz";
        sha512 = "83311d3f354567612dc16c1ae2ea9b503d6f6833aa4e138d39aa229da3f3bb99b0e4d7cca0bce4796b0060d6a51d8113eb7449ed5dc0e7900bf217107ea5bff9";
      };
      aarch64-linux = {
        path = "linux-arm/cli_linux_arm64.tar.gz";
        sha512 = "c9b29bba475f63a1a80161ae93ba72b221c7a586d9851e4d0061546704bab66d6b2760b25d716d191724fc7564f3246456ee151e28aa37af48dbcd72bdc6c463";
      };
    }
    .${stdenv.hostPlatform.system};

  unwrapped = unstable.antigravity-cli.overrideAttrs {
    inherit version;
    src = fetchurl {
      url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-${build}/${artifact.path}";
      inherit (artifact) sha512;
    };
  };
in
# A store binary can't replace itself, so agy's background updater only fails.
symlinkJoin {
  pname = "antigravity-cli";
  inherit version;
  paths = [ unwrapped ];
  nativeBuildInputs = [ makeBinaryWrapper ];
  postBuild = ''
    wrapProgram $out/bin/agy --set AGY_CLI_DISABLE_AUTO_UPDATE true
  '';
  meta = unwrapped.meta // {
    platforms = lib.platforms.linux;
  };
}
