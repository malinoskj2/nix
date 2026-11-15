{
  cargo,
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
}:
stdenvNoCC.mkDerivation {
  pname = "cargo-preferences";
  version = "1";
  src = ./.;
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    cargo
    python3
  ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python -m unittest discover -s tests -v
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm644 cargo_preferences.py $out/lib/cargo-preferences/cargo_preferences.py
    install -m644 preferences.toml guide.md $out/lib/cargo-preferences/
    makeWrapper ${python3}/bin/python3 $out/bin/cargo-preferences \
      --add-flags $out/lib/cargo-preferences/cargo_preferences.py
    runHook postInstall
  '';
  meta = {
    description = "Check direct Cargo dependency preferences and project boundaries";
    mainProgram = "cargo-preferences";
    platforms = lib.platforms.unix;
  };
}
