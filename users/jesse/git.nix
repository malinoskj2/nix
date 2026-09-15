{
  programs.git = {
    enable = true;

    signing.key = "6E46C98F55BE7FF3";

    includes = [
      {
        condition = "gitdir:~/projects/work/";
        contents = {
          user.email = "jmalinosky@insiderealestate.com";
          commit.gpgsign = false;
        };
      }
    ];

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

      color.ui = "auto";

      # Detect whitespace errors when applying a patch
      apply.whitespace = "fix";

      core = {
        editor = "vim";
        pager = "less -R";
        autocrlf = false;
      };

      merge.ff = "yes";
      commit.gpgsign = false;
      gpg.program = "gpg2";
      credential.helper = "cache --timeout 43200";

      # Detect copies as well as renames
      diff.renames = "copies";

      submodule.recurse = true;

      safe.directory = "/home/jesse/nix";
    };
  };

  programs.git.ignores = [
    ".idea/"
    "docker-compose.override.yml"
    "/storage/"
    "phpcs.xml"
    "phpmd.xml"
    "**/.claude/settings.local.json"
  ];
}
