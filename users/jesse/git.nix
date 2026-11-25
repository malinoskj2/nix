{
  config,
  lib,
  pkgs,
  ...
}:
{
  programs.git = {
    enable = true;
    package = pkgs.betterleaks-push-gate.git;
    signing = {
      format = "openpgp";
      key = "6E46C98F55BE7FF3";
    };
    settings = {
      user = {
        name = "Jesse Malinosky";
        email = "jesse@malinoskj2.dev";
      };
      alias = {
        cloners = "clone --recurse-submodules";
        lg = "log --color --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit";
        pom = "push origin master";
        ruop = "remote update origin --prune";
        subupdate = "submodule update --remote";
      };
      apply.whitespace = "fix";
      core.editor = "vim";
      credential.helper = "cache --timeout 43200";
      diff.renames = "copies";
      # A config hook runs before the repository's own pre-push hook, wherever core.hooksPath points.
      hook.betterleaks-push-gate = {
        event = "pre-push";
        command = lib.getExe pkgs.betterleaks-push-gate;
      };
      init.defaultBranch = "main";
      safe.directory = "${config.home.homeDirectory}/nix";
      submodule.recurse = true;
    };

    # The order reaches git's ignore file, so this list stays unsorted.
    ignores = [
      "/.tmp/"
      ".idea/"
      "docker-compose.override.yml"
      "/storage/"
      "phpcs.xml"
      "phpmd.xml"
      "**/.claude/settings.local.json"
    ];
  };
}
