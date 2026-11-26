{ lib, isHome }:
let
  homeSkills = [
    "audio-transcribe"
    "qwen-prompt"
    "qwen-uncensored-prompt"
  ];
in
{
  context = lib.concatMapStringsSep "\n" builtins.readFile (
    [ ./claude/rules/worktrees.md ]
    ++ lib.optionals isHome [
      ./claude/rules/gpu.md
      ./claude/rules/host-switch.md
    ]
    ++ [
      ./claude/rules/agent-team.md
      ./claude/rules/documentation.md
      ./claude/rules/git-push.md
      ./claude/rules/local-models.md
      ./claude/rules/media.md
      ./claude/rules/nix-run.md
      ./claude/rules/sandbox-display.md
      ./claude/rules/sandbox-previews.md
      ./claude/rules/tool-output.md
    ]
  );

  skills =
    if isHome then
      ./claude/skills
    else
      builtins.path {
        name = "skills";
        path = ./claude/skills;
        filter =
          path: _: !(dirOf path == toString ./claude/skills && lib.elem (baseNameOf path) homeSkills);
      };
}
