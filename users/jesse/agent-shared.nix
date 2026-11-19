{ lib, queue }:
let
  queueSkills = [
    "audio-transcribe"
    "qwen-prompt"
    "qwen-uncensored-prompt"
    "work-queue"
  ];
in
{
  context = lib.concatMapStringsSep "\n" builtins.readFile (
    [ ./claude/rules/worktrees.md ]
    ++ lib.optionals queue [
      ./claude/rules/gpu.md
      ./claude/rules/resources.md
      ./claude/rules/host-switch.md
    ]
    ++ [
      ./claude/rules/local-models.md
      ./claude/rules/media.md
      ./claude/rules/sandbox-display.md
      ./claude/rules/sandbox-previews.md
      ./claude/rules/tool-output.md
    ]
  );

  skills =
    if queue then
      ./claude/skills
    else
      builtins.path {
        name = "skills";
        path = ./claude/skills;
        filter =
          path: _: !(dirOf path == toString ./claude/skills && lib.elem (baseNameOf path) queueSkills);
      };
}
