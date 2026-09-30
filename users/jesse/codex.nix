{ lib, pkgs, ... }:
let
  tomlFormat = pkgs.formats.toml { };
  claudeAgents = ./claude/agents;
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
        {
          inherit name;
          inherit (agent) description;
          developer_instructions = ''
            Load and follow the `${"$"}${agent.skill}` skill before doing the assigned work.
            The shared definition below includes Claude Code YAML front matter. Treat
            that front matter as metadata and follow the Markdown instructions.

            ${builtins.readFile agent.source}
          '';
        }
        // lib.optionalAttrs (agent ? sandbox_mode) {
          inherit (agent) sandbox_mode;
        }
      );
    };
  settings = tomlFormat.generate "codex-settings.toml" {
    tui.alternate_screen = "never";
  };
  # Codex saves folder trust and model choices to its own config.toml, so it
  # has to be a writable file with these settings merged in, not a store link.
  mergeSettings =
    pkgs.writers.writePython3 "codex-merge-settings"
      {
        libraries = [ pkgs.python3Packages.tomlkit ];
      }
      ''
        import sys
        from collections.abc import MutableMapping
        from pathlib import Path

        import tomlkit


        def merge(dst, src):
            for key, value in src.items():
                old = dst.get(key)
                if isinstance(old, MutableMapping) and isinstance(
                    value, MutableMapping
                ):
                    merge(old, value)
                else:
                    dst[key] = value


        settings = tomlkit.parse(Path(sys.argv[1]).read_text())
        target = Path(sys.argv[2])
        if target.exists():
            config = tomlkit.parse(target.read_text())
        else:
            config = tomlkit.document()
        merge(config, settings)
        target.unlink(missing_ok=True)
        target.write_text(tomlkit.dumps(config))
      '';
in
{
  programs.codex = {
    enable = true;
    package = null;
    skills = ./claude/skills;
    context = lib.concatMapStringsSep "\n" builtins.readFile [
      ./claude/rules/worktrees.md
      ./claude/rules/media.md
    ];
  };

  home.file = lib.mapAttrs' mkAgent agents;

  home.activation.codexSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run mkdir -p "$HOME/.codex"
    run ${mergeSettings} ${settings} "$HOME/.codex/config.toml"
  '';
}
