{ config, ... }:
{
  programs.git = {
    enable = true;
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
      safe.directory = "${config.home.homeDirectory}/nix";
      submodule.recurse = true;
    };

    # The order reaches git's ignore file, so this list stays unsorted.
    ignores = [
      ".idea/"
      "docker-compose.override.yml"
      "/storage/"
      "phpcs.xml"
      "phpmd.xml"
      "**/.claude/settings.local.json"
      ".beads/"
    ];
  };
}
