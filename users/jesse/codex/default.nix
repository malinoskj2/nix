{ lib, pkgs, ... }:
let
  codexAgentFormat = pkgs.formats.toml { };
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
  };
  mkAgent =
    name: agent:
    lib.nameValuePair ".codex/agents/${name}.toml" {
      source = codexAgentFormat.generate "codex-agent-${name}.toml" (
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
in
{
  programs.codex = {
    enable = true;
    package = null;
    skills = ../claude/skills;
  };

  home.file = lib.mapAttrs' mkAgent agents;
}
