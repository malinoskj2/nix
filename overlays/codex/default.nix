{
  codex,
  fetchFromGitHub,
}:
codex.overrideAttrs (finalAttrs: {
  version = "0.169.0";
  buildCommit = "d32063f96c2dff1dc96af839b3952abb6acfeda4";
  src = fetchFromGitHub {
    owner = "openai";
    repo = "codex";
    rev = finalAttrs.buildCommit;
    hash = "sha256-p8Vw0Vu8ufPY35k/RkcKE6HOTMJta2J9W33ei/7in+A=";
  };
  cargoHash = "sha256-+YSkZwmAP88AOFmNWav4ye4ObbDYAIo0mzeQEzTqDm8=";
})
