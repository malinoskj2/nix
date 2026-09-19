{
  inputs,
  lib,
  pkgs,
  ...
}:
let
  archive-completed-task = pkgs.writeShellApplication {
    name = "archive-completed-task";
    runtimeInputs = [ pkgs.jq ];
    text = builtins.readFile ./archive-completed-task.sh;
  };
in
{
  programs.claude-code = {
    enable = true;
    package = pkgs.unstable.claude-code;
    context = ./CLAUDE.md;
    plugins = [ inputs.caveman ];
    skills = {
      gauntlet = ./skills/gauntlet;
      laravel-review-jesse = ./skills/laravel-review-jesse;
    };

    settings = {
      model = "claude-fable-5-1[1m]";
      effortLevel = "high";
      theme = "dark";
      skipDangerousModePermissionPrompt = true;
      inputNeededNotifEnabled = true;
      agentPushNotifEnabled = true;
      attribution = {
        commit = "";
        pr = "";
      };
      env = {
        CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
        CLAUDE_CODE_ENABLE_TODO_TOOLS = "1";
      };
      hooks.PostToolUse = [
        {
          matcher = "TaskUpdate";
          hooks = [
            {
              type = "command";
              command = lib.getExe archive-completed-task;
            }
          ];
        }
      ];
      statusLine = {
        type = "command";
        command = "bash ${inputs.caveman}/src/hooks/caveman-statusline.sh";
      };

      permissions = {
        allow = [
          "Bash(ls:*)"
          "Bash(find:*)"
          "Bash(cat:*)"
          "Bash(grep:*)"
          "Bash(rg:*)"
          "Bash(fd:*)"
          "Bash(git status:*)"
          "Bash(git log:*)"
          "Bash(git diff:*)"
          "Bash(git branch:*)"
          "Bash(git show:*)"
          "Bash(git add:*)"
          "Bash(git commit:*)"
          "Bash(nix flake show:*)"
          "Bash(nix flake check:*)"
        ];
        ask = [ "Bash(git push:*)" ];
        # Deny rules hold even when permission prompts are bypassed.
        deny = [
          "Read(~/.ssh/**)"
          "Read(~/.gnupg/**)"
          "Read(**/.env)"
          "Read(**/secrets/**)"
          "Bash(nh os switch:*)"
          "Bash(nixos-rebuild switch:*)"
          "Bash(home-manager switch:*)"
          "Bash(darwin-rebuild switch:*)"
          "Bash(git push --force:*)"
          "Bash(git push -f:*)"
          "Bash(git reset --hard:*)"
          "Bash(rm -rf /:*)"
        ];
      };
    };
  };
}
