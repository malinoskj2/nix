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
  version = "1.5.12";
  build = "5281398513336320";

  artifact =
    {
      x86_64-linux = {
        path = "linux-x64/cli_linux_x64.tar.gz";
        sha512 = "26de25fccb3fbf0b093e090ce14a14ac1df1ec3e90ef4ea6106887d3a81b0cc9edb0dadea7b9101d07f9606eba159062a6fb7b78e91b73f7520684a24db73428";
      };
      aarch64-linux = {
        path = "linux-arm/cli_linux_arm64.tar.gz";
        sha512 = "1030d89ce9e5cb39509e272cb89b71fde0e0d5d6527b7392525d5ef2683da54fb49230449107486d91c02ded39a678faaa649b2041304a6cf82a3a332d5819d9";
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
