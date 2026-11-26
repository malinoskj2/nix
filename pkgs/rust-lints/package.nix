{
  cargo,
  clippy,
  fetchCrate,
  git,
  jq,
  lib,
  libgit2,
  makeRustPlatform,
  makeWrapper,
  openssl,
  pkg-config,
  python3,
  runCommand,
  rust-bin,
  stdenv,
  zlib,
}:
let
  nightlyDate = "2026-11-12";
  toolchainName = "nightly-${nightlyDate}-${stdenv.hostPlatform.rust.rustcTarget}";
  dylintVersion = "6.4.0";
  clippyUtilsVersion = "0.1.102";

  toolchain = rust-bin.nightly.${nightlyDate}.minimal.override {
    extensions = [
      "rustc-dev"
      "llvm-tools"
    ];
  };

  nightlyPlatform = makeRustPlatform {
    cargo = toolchain;
    rustc = toolchain;
  };

  dylintCrate =
    pname: hash: cargoHash:
    let
      src = fetchCrate {
        inherit pname hash;
        version = dylintVersion;
      };
    in
    nightlyPlatform.buildRustPackage {
      inherit pname src cargoHash;
      version = dylintVersion;
      nativeBuildInputs = [ pkg-config ];
      buildInputs = [
        libgit2
        openssl
        zlib
      ];
      env.LIBGIT2_NO_VENDOR = "1";
      preBuild = vendoredDylint;
      doCheck = false;
    };

  # dylint's build script points the driver at a sibling checkout unless its source lies under
  # CARGO_HOME, as a registry download does.
  vendoredDylint = ''
    export CARGO_HOME=$cargoDepsCopy
  '';

  cargo-dylint-unwrapped =
    dylintCrate "cargo-dylint" "sha256-ZSQyGdBvhDTLam8b/B+LW5WuIog0T6kjUGAY3DpuLN4="
      "sha256-djxEyVPoFysY615fmXqTyN8AIPKx1oEMirEBsC9LoOw=";
  dylint-link =
    dylintCrate "dylint-link" "sha256-I2DdWEZTL+WY++OIE11Ej7liwlXzwvC+5T0vOBk+dfc="
      "sha256-5IJP3ZwCqOcyM3RKVU9Terc9LSheCcS5BMNimuLb7AE=";

  clippyUtils = fetchCrate {
    pname = "clippy_utils";
    version = clippyUtilsVersion;
    hash = "sha256-Ma918WgqFfuh29/38ibKPKHit8fyBNzMV0rEDLCHsPU=";
  };

  # dylint_driver's build script reads clippy_utils' interned symbols from a Clippy Git
  # checkout, taking the newest commit whose parent pins another channel. This repository
  # holds only the files it reads, for the pinned nightly.
  clippyRepoScript = ''
    export DYLINT_CLIPPY_REPO=$TMPDIR/clippy
    mkdir -p $DYLINT_CLIPPY_REPO/clippy_utils/src
    cp ${clippyUtils}/src/sym.rs $DYLINT_CLIPPY_REPO/clippy_utils/src/
    printf '[package]\nname = "clippy_utils"\nversion = "%s"\n' ${clippyUtilsVersion} \
      > $DYLINT_CLIPPY_REPO/clippy_utils/Cargo.toml
    commit() {
      printf '[toolchain]\nchannel = "%s"\n' "$1" > $DYLINT_CLIPPY_REPO/rust-toolchain.toml
      git -C $DYLINT_CLIPPY_REPO add .
      git -C $DYLINT_CLIPPY_REPO -c user.name=nix -c user.email=nix@localhost commit -qm "$1"
    }
    git -C $DYLINT_CLIPPY_REPO init -q
    commit nightly-2000-01-01
    commit nightly-${nightlyDate}
  '';

  driver = nightlyPlatform.buildRustPackage {
    pname = "dylint-driver";
    version = dylintVersion;
    src = ./driver;
    cargoLock.lockFile = ./driver/Cargo.lock;
    nativeBuildInputs = [ git ];
    env = {
      RUSTUP_TOOLCHAIN = toolchainName;
      RUSTFLAGS = "-C link-args=-Wl,-rpath,${toolchain}/lib";
    };
    preBuild = clippyRepoScript;
    postInstall = ''
      mkdir -p $out/${toolchainName}
      mv $out/bin/dylint-driver $out/${toolchainName}/dylint-driver
      rmdir $out/bin
    '';
    doCheck = false;
  };

  lintLibrary = nightlyPlatform.buildRustPackage {
    pname = "jesse-lints";
    version = "0.1.0";
    src = ./lints;
    cargoLock.lockFile = ./lints/Cargo.lock;
    nativeBuildInputs = [ dylint-link ];
    env = {
      RUSTUP_TOOLCHAIN = toolchainName;
      DYLINT_DRIVER_PATH = driver;
      "CARGO_TARGET_${
        lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] stdenv.hostPlatform.rust.rustcTarget)
      }_LINKER" =
        "dylint-link";
    };
    preBuild = vendoredDylint;
    # dylint_testing rebuilds the library and expects it in target/debug, without a target triple.
    checkPhase = ''
      runHook preCheck
      env -u CARGO_BUILD_TARGET cargo test --offline -j $NIX_BUILD_CORES
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      library=$(find target -name libjesse_lints.so -path '*/release/*' | head -n 1)
      install -Dm755 "$library" "$out/lib/libjesse_lints@${toolchainName}.so"
      runHook postInstall
    '';
  };

  python = python3.withPackages (ps: [ ps.tomli-w ]);
in
stdenv.mkDerivation (finalAttrs: {
  pname = "rust-lints";
  version = "1";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./clippy.toml
      ./clippy_groups.py
      ./lints.toml
      ./lints/src
      ./rust-lints-rustc-wrapper.sh
      ./rust_lints.py
      ./tests
    ];
  };
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ python ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    RUST_LINTS_DATA=$PWD python -m unittest discover -s tests -v
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    share=$out/share/rust-lints
    install -Dm644 -t $share lints.toml clippy.toml rust_lints.py
    install -Dm755 rust-lints-rustc-wrapper.sh $share/rust-lints-rustc-wrapper
    mkdir -p $share/lib $share/dylint
    ln -s ${lintLibrary}/lib/* $share/lib/
    cp -r lints/src $share/dylint/src
    grep -hE '^    pub [A-Z_]+,$' lints/src/*.rs | sed 's/ *pub //; s/,//' | tr A-Z a-z | sort \
      > $share/dylint-lints.txt
    ${clippy}/bin/clippy-driver rustc -W help | ${python.interpreter} clippy_groups.py \
      > $share/clippy-groups.json
    makeWrapper ${python.interpreter} $out/bin/rust-lints \
      --add-flags $share/rust_lints.py \
      --set RUST_LINTS_DATA $share \
      --set RUST_LINTS_CARGO_DYLINT $out/bin/cargo-dylint
    makeWrapper ${cargo-dylint-unwrapped}/bin/cargo-dylint $out/bin/cargo-dylint \
      --prefix PATH : ${toolchain}/bin \
      --set-default DYLINT_DRIVER_PATH ${driver} \
      --unset RUSTUP_HOME
    ln -s ${dylint-link}/bin/dylint-link $out/bin/dylint-link
    runHook postInstall
  '';
  passthru = {
    tests.fixture =
      runCommand "rust-lints-fixture"
        {
          nativeBuildInputs = [
            cargo
            clippy
            jq
            stdenv.cc
          ];
        }
        ''
          export HOME=$TMPDIR
          cp -r ${./tests/fixture} fixture
          chmod -R u+w fixture
          status=0
          ${finalAttrs.finalPackage}/bin/rust-lints --offline --json --manifest-path fixture/Cargo.toml > report.json || status=$?
          jq . report.json
          test "$status" = 1
          lints=$(jq -r '[.findings[].lint] | sort | unique | join(" ")' report.json)
          for lint in catch_all_module clippy::disallowed_methods missing_item_separator stringly_error; do
            case " $lints " in *" $lint "*) ;; *) echo "missing $lint in: $lints"; exit 1 ;; esac
          done
          case " $lints " in *" clippy::unwrap_used "*) echo "project allow was overridden"; exit 1 ;; esac
          jq -e '.project_overrides[] | select(.lint == "clippy::unwrap_used" and .project == "allow")' report.json

          cp -r ${./tests/dependency-fixture} dependency
          chmod -R u+w dependency
          status=0
          ${finalAttrs.finalPackage}/bin/rust-lints --offline --json --manifest-path dependency/app/Cargo.toml > dependency.json || status=$?
          jq . dependency.json
          test "$status" = 2
          jq -e '.status == "failed" and (.errors | any(contains("missing_function")))' dependency.json
          touch $out
        '';
    inherit
      driver
      dylint-link
      lintLibrary
      toolchain
      toolchainName
      ;
    cargo-dylint = cargo-dylint-unwrapped;
  };
  meta = {
    description = "Jesse's shared Rust lint set and a runner for any Cargo project";
    mainProgram = "rust-lints";
    platforms = lib.platforms.linux;
  };
})
