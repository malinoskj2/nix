{
  perSystem =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      devShells.default = pkgs.mkShellNoCC {
        packages = [
          config.treefmt.build.wrapper
          pkgs.nh
          pkgs.nixd
          pkgs.nvd
        ]
        # ruff-check and ruff-format share one package.
        ++ lib.unique (builtins.attrValues config.treefmt.build.programs);
      };
    };
}
