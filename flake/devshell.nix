{
  perSystem =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # Editors call the formatters directly, and ruff-check and ruff-format share one package.
      formatters = lib.unique (lib.attrValues config.treefmt.build.programs);
    in
    {
      devShells.default = pkgs.mkShellNoCC {
        packages = [
          config.treefmt.build.wrapper
          pkgs.nh
          pkgs.nixd
          pkgs.nvd
        ]
        ++ formatters;
      };
    };
}
