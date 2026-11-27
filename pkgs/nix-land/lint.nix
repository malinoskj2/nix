{
  src,
  rev,
  manifest,
}:
let
  pkgs = import "@nixpkgs@" { system = builtins.currentSystem; };
  rustLints = builtins.storePath "@rustLints@";
  tree = builtins.fetchGit {
    url = src;
    inherit rev;
    allRefs = true;
  };
  workspace = dirOf manifest;
  vendor = pkgs.rustPlatform.importCargoLock {
    lockFile = tree + "/${workspace}/Cargo.lock";
    allowBuiltinFetchGit = true;
  };
in
# Build scripts and proc macros run here, in the Nix build sandbox without network, never as
# the landing user.
pkgs.runCommand "nix-land-rust-lints"
  {
    nativeBuildInputs = with pkgs; [
      cargo
      clippy
      openssl
      pkg-config
      stdenv.cc
      zlib
    ];
  }
  ''
    export HOME=$TMPDIR CARGO_HOME=$TMPDIR/cargo-home
    cp -r ${tree} src
    chmod -R u+w src
    mkdir .cargo
    ln -s ${vendor} cargo-vendor-dir
    sed 's|@vendor[@]|${vendor}|g' ${vendor}/.cargo/config.toml >.cargo/config.toml
    status=0
    ${rustLints}/bin/rust-lints --offline --json --manifest-path "src/${manifest}" >report.json 2>log || status=$?
    mkdir $out
    mv report.json log $out/
    echo "$status" >$out/status
  ''
