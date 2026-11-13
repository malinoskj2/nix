{
  fetchurl,
  ffmpeg-headless,
  git,
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
}:
let
  fontsource =
    name: version: hash:
    fetchurl {
      url = "https://registry.npmjs.org/@fontsource${name}/-/${baseNameOf name}-${version}.tgz";
      inherit hash;
    };
  fonts = [
    (fontsource "-variable/newsreader" "5.3.0"
      "sha512-rrzYi43qMpbzwuFtf9OkWH8sxAPVPcQQQEwXpPtwaKYeJ8yVg5aLs5kawmo1f2Q1t1M38TLmEKCkGVDsYwgdFw=="
    )
    (fontsource "-variable/ibm-plex-sans" "5.3.0"
      "sha512-agG8tXFEo0hD9+J7npa4vbbWult52eMLVaQ6WQRlhs/iCAojrMAoejru85W9HTVXHfyUj96KM7gp/KGAS87XaQ=="
    )
    (fontsource "/ibm-plex-mono" "5.3.0"
      "sha512-eTgnZjZEGk1QtD3ZstF+Vclo2HLAni8YMy34/DxllwZvyz1lR/1RF/xTiAquOBO7MvqBx8D2Ig2WCPMVfdZu7Q=="
    )
  ];
  fontFiles = [
    "newsreader-latin-opsz-normal.woff2"
    "newsreader-latin-opsz-italic.woff2"
    "ibm-plex-sans-latin-wght-normal.woff2"
    "ibm-plex-mono-latin-400-normal.woff2"
    "ibm-plex-mono-latin-500-normal.woff2"
  ];
in
stdenvNoCC.mkDerivation {
  pname = "media-gallery";
  version = "1";
  src = ./.;
  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ python3 ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python -m unittest discover -s tests -v
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm644 media_gallery.py $out/lib/media-gallery/media_gallery.py
    install -Dm644 gallery.html $out/lib/media-gallery/gallery.html
    mkdir -p fonts $out/lib/media-gallery/fonts
    for tarball in ${lib.escapeShellArgs fonts}; do
      tar -xzf "$tarball" -C fonts --strip-components=2 package/files
    done
    for font in ${lib.escapeShellArgs fontFiles}; do
      install -Dm644 "fonts/$font" "$out/lib/media-gallery/fonts/$font"
    done
    makeWrapper ${lib.getExe python3} $out/bin/media-gallery \
      --add-flags $out/lib/media-gallery/media_gallery.py \
      --prefix PATH : ${
        lib.makeBinPath [
          ffmpeg-headless
          git
        ]
      }
    runHook postInstall
  '';
  meta = {
    description = "Live, mobile-friendly gallery for reviewing images and videos an agent produced";
    mainProgram = "media-gallery";
  };
}
