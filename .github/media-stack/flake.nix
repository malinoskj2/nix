{
  description = "Stands in for the private media-stack input in CI";

  outputs = _: {
    nixosModules.default =
      { lib, ... }:
      {
        options.services.media-stack = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
  };
}
