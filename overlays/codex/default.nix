{
  codex,
  fetchFromGitHub,
}:
codex.overrideAttrs (finalAttrs: {
  version = "0.169.1";
  buildCommit = "c376cf7396eff83ce4c6ac61b9553df142e7a0be";
  src = fetchFromGitHub {
    owner = "openai";
    repo = "codex";
    rev = finalAttrs.buildCommit;
    hash = "sha256-XSHlHyI6hfwRCzmj5nEfmW3RTx9CpDhk+ny8WZQ2gNs=";
  };
  cargoHash = "sha256-+YSkZwmAP88AOFmNWav4ye4ObbDYAIo0mzeQEzTqDm8=";
})
