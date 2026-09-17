{ lib, ... }:
{
  programs.starship = {
    enable = true;

    settings = {
      add_newline = false;

      format = lib.concatMapStrings (module: "$" + module) (
        [
          "username"
          "git_branch"
          "git_status"
        ]
        # Language and environment modules that appear only in a matching project or shell.
        ++ [
          "bun"
          "c"
          "daml"
          "fortran"
          "gleam"
          "gradle"
          "haskell"
          "haxe"
          "maven"
          "mojo"
          "odin"
          "opa"
          "quarto"
          "raku"
          "solidity"
          "typst"
          "xmake"
          "buf"
          "guix_shell"
          "pixi"
          "meson"
          "spack"
          "container"
          "netns"
        ]
        ++ [ "character" ]
      );

      username = {
        format = "[$user ]($style)";
        style_user = "bold";
        show_always = true;
      };

      git_branch = {
        format = "[$symbol$branch]($style) ";
        symbol = "➜ ";
        truncation_length = 7;
        truncation_symbol = "";
      };

      git_status = {
        style = "bold red";
        untracked = "!";
        modified = "!";
        staged = "!";
        stashed = "";
        ahead = "";
        behind = "";
        diverged = "";
      };

      character = {
        success_symbol = "[➜](bold green)";
        error_symbol = "[➜](bold red)";
      };
    };
  };
}
