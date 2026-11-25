{
  dmidecode,
  fetchFromGitHub,
  fetchzip,
  lib,
  libnotify,
  mprime,
  python3Packages,
  qt6,
  stress-ng,
  stressapptest,
  util-linux,
  y-cruncher,
}:

let
  # nixpkgs' download.mersenne.ca URL serves an HTML page; mersenne.org has the same archive.
  mprime' = mprime.overrideAttrs (old: {
    src = fetchzip {
      url = "https://www.mersenne.org/download/software/v31/31.04/p95v3104b02.source.zip";
      hash = old.src.outputHash;
      stripRoot = false;
    };
  });
in
python3Packages.buildPythonApplication {
  pname = "corecycler";
  version = "0.0.1-unstable-2026-11-08";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "Daaboulex";
    repo = "linux-corecycler";
    rev = "f4d3813527c7d8bde7205232e034c9dd14fd1283";
    hash = "sha256-QmbIIlKeXTkSVVSiopqaKUdNS97tj8Kyieu7mdDF01g=";
  };

  build-system = [
    python3Packages.setuptools
    python3Packages.setuptools-scm
  ];

  dependencies = [ python3Packages.pyside6 ];

  nativeBuildInputs = [ qt6.wrapQtAppsHook ];
  buildInputs = [ qt6.qtbase ];

  nativeCheckInputs = [
    python3Packages.pytestCheckHook
    python3Packages.hypothesis
  ];
  preCheck = ''
    export QT_QPA_PLATFORM=offscreen
    export HOME=$TMPDIR
  '';
  disabledTestMarks = [ "slow" ];

  dontWrapQtApps = true;
  preFixup = ''
    makeWrapperArgs+=("''${qtWrapperArgs[@]}")
    makeWrapperArgs+=(--prefix PATH : ${
      lib.makeBinPath [
        mprime'
        y-cruncher
        stress-ng
        stressapptest
        util-linux
        dmidecode
        libnotify
      ]
    })
  '';

  postInstall = ''
    install -Dm644 assets/icon.svg $out/share/icons/hicolor/scalable/apps/corecycler.svg
    install -Dm644 assets/corecycler.desktop $out/share/applications/corecycler.desktop
    install -Dm644 -t $out/share/corecycler/assets assets/*.svg
  '';

  meta = {
    description = "Per-core CPU stability tester and PBO Curve Optimizer tuner for AMD Ryzen";
    homepage = "https://github.com/Daaboulex/linux-corecycler";
    license = lib.licenses.gpl3Plus;
    mainProgram = "corecycler";
    platforms = [ "x86_64-linux" ];
  };
}
