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
        # Not a considered choice: the config used to keep the default `$all` format and disable
        # modules one by one, and these are the ones that list missed. They are kept only so the
        # prompt still renders exactly as before.
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
        show_always = true;
        format = "[$user ]($style)";
        style_user = "bold";
      };

      git_branch = {
        symbol = "➜ ";
        format = "[$symbol$branch]($style) ";
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
