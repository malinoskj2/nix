{
  config,
  lib,
  pkgs,
  ...
}:
let
  tomlFormat = pkgs.formats.toml { };
  claudeAgents = ../claude/agents;
  agents = {
    laravel-builder = {
      description = "Implements Laravel/PHP features, fixes and requested refactors using Jesse's architecture, abstraction and aesthetics standards.";
      source = claudeAgents + "/laravel-builder.md";
      skill = "laravel-build-jesse";
    };
    laravel-orchestrator = {
      description = "Coordinates autonomous Laravel/PHP implementation and independent review through laravel-builder and laravel-reviewer.";
      source = claudeAgents + "/laravel-orchestrator.md";
      skill = "laravel-orchestrator";
    };
    laravel-reviewer = {
      description = "Reviews Laravel/PHP changes for requirements, correctness, design, abstraction and aesthetics without applying changes.";
      source = claudeAgents + "/laravel-reviewer.md";
      skill = "laravel-review-jesse";
      sandbox_mode = "read-only";
    };
    rust-builder = {
      description = "Implements Rust features, fixes and refactors using repository-specific standards and idiomatic Rust design.";
      source = claudeAgents + "/rust-builder.md";
      skill = "rust-build-jesse";
    };
    rust-reviewer = {
      description = "Reviews Rust changes for requirements, correctness, failure safety, bounded operation and design without applying changes.";
      source = claudeAgents + "/rust-reviewer.md";
      skill = "rust-review-jesse";
      sandbox_mode = "read-only";
    };
  };
  mkAgent =
    name: agent:
    lib.nameValuePair ".codex/agents/${name}.toml" {
      source = tomlFormat.generate "codex-agent-${name}.toml" (
        removeAttrs agent [
          "skill"
          "source"
        ]
        // {
          inherit name;
          developer_instructions = ''
            Load and follow the `''$${agent.skill}` skill before doing the assigned work.
            The shared definition below includes Claude Code YAML front matter. Treat
            that front matter as metadata and follow the Markdown instructions.

            ${builtins.readFile agent.source}
          '';
        }
      );
    };
  settings = tomlFormat.generate "codex-settings.toml" config.programs.codex.settings;
  # Codex saves folder trust and model choices to its own config.toml, so it
  # has to be a writable file with these settings merged in, not a store link.
  mergeSettings = pkgs.writers.writePython3 "codex-merge-settings" {
    libraries = [ pkgs.python3Packages.tomlkit ];
    # Ruff formats this repository at 120 columns; retain the other checks.
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./merge-settings.py);
in
{
  programs.codex = {
    enable = true;
    package = pkgs.unstable.codex;
    skills = ../claude/skills;
    settings.tui.alternate_screen = "never";
    context = lib.concatMapStringsSep "\n" builtins.readFile [
      ../claude/rules/worktrees.md
      ../claude/rules/media.md
      ../claude/rules/sandbox-display.md
    ];
  };

  home.file = lib.mapAttrs' mkAgent agents // {
    ".codex/config.toml".enable = lib.mkForce false;
  };

  home.activation.codexSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run mkdir -p "$HOME/.codex"
    run ${mergeSettings} ${settings} "$HOME/.codex/config.toml"
  '';
}
