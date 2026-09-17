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
        pom = "push origin master";
        cloners = "clone --recurse-submodules";
        ruop = "remote update origin --prune";
        lg = "log --color --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit";
        subupdate = "submodule update --remote";
      };

      core.editor = "vim";

      apply.whitespace = "fix";
      credential.helper = "cache --timeout 43200";
      diff.renames = "copies";
      submodule.recurse = true;
      safe.directory = "${config.home.homeDirectory}/nix";
    };

    ignores = [
      ".idea/"
      "docker-compose.override.yml"
      "/storage/"
      "phpcs.xml"
      "phpmd.xml"
      "**/.claude/settings.local.json"
    ];
  };
}
