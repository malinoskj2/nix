{
  fetchFromGitHub,
  lib,
  pkg-config,
  openssl,
  rustPlatform,
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "beads_rust";
  version = "0.6.0";

  src = fetchFromGitHub {
    owner = "Dicklesworthstone";
    repo = "beads_rust";
    tag = "v${finalAttrs.version}";
    hash = "sha256-dTYOCTji4sz1HlVayT08UhXRuA7Vg8bkCtc6Az9xrxY=";
  };

  cargoHash = "sha256-1qYfXWZwVNGLWAPUn2YSpyhUKzJP0HNf3oIjs07Cf3I=";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  # The binary comes from the store, so it must not replace itself.
  buildNoDefaultFeatures = true;

  # fsqlite-pager enables core_intrinsics, which upstream builds with nightly.
  env.RUSTC_BOOTSTRAP = 1;

  doCheck = false;

  meta = {
    description = "Agent-first issue tracker (SQLite + JSONL)";
    homepage = "https://github.com/Dicklesworthstone/beads_rust";
    license = lib.licenses.mit;
    mainProgram = "br";
  };
})
