{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem.treefmt = {
    programs = {
      deadnix.enable = true;
      nixfmt.enable = true;
      ruff-check.enable = true;
      ruff-format.enable = true;
      shellcheck.enable = true;

      shfmt = {
        enable = true;
        # Simplifying would unquote the expansions that the scripts quote inside [[ ]].
        simplify = false;
      };

      statix.enable = true;
      stylua.enable = true;
    };

    settings = {
      global.excludes = [ "hosts/*/hardware-configuration.nix" ];

      formatter = {
        # direnv's stdlib, not a standalone shell script.
        shellcheck.excludes = [ ".envrc" ];

        # Indents switch cases; programs.shfmt has no option for it.
        shfmt.options = [ "-ci" ];

        # Noctalia plugin scripts are Luau, which StyLua parses alongside Lua.
        stylua.includes = [ "*.luau" ];

        # Lint before formatting so fixes are formatted in the same run.
        deadnix.priority = 1;
        statix.priority = 2;
        nixfmt.priority = 3;
        ruff-check.priority = 1;
        ruff-format.priority = 2;
      };
    };
  };
}
