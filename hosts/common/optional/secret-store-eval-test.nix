{ inputs, pkgs }:
let
  inherit (pkgs) lib;
  evaluate =
    modules:
    (inputs.nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./agent-broker.nix
        {
          nixpkgs.pkgs = pkgs;
          boot.isContainer = true;
          users.users.jesse.isNormalUser = true;
          system.stateVersion = "26.05";
        }
      ]
      ++ modules;
    }).config;
  failures = modules: map (a: a.message) (lib.filter (a: !a.assertion) (evaluate modules).assertions);
  fails = needle: modules: lib.any (lib.hasInfix needle) (failures modules);
  evalFails =
    modules: attr: !(builtins.tryEval (builtins.deepSeq (attr (evaluate modules)) true)).success;

  cases = {
    valid =
      failures [
        {
          secrets.host.venice-api-key.owner = "jesse";
          agentBroker.secrets.github-token.inject.hosts = [ "api.github.com" ];
        }
      ] == [ ];
    both-kinds = fails "never both" [
      {
        secrets.host.token.owner = "jesse";
        agentBroker.secrets.token = { };
      }
    ];
    shared-key = fails "exactly one consumer kind" [
      {
        secrets.host.a = {
          owner = "jesse";
          key = "token";
        };
        agentBroker.secrets.b.key = "token";
      }
    ];
    broker-mode = fails "must stay agent-broker" [
      {
        agentBroker.secrets.token = { };
        sops.secrets.token.mode = lib.mkForce "0440";
      }
    ];
    broker-owner = fails "must stay agent-broker" [
      {
        agentBroker.secrets.token = { };
        sops.secrets.token.owner = lib.mkForce "jesse";
      }
    ];
    host-as-broker = fails "can't belong to agent-broker" [
      { secrets.host.token.owner = "agent-broker"; }
    ];
    host-world-readable = evalFails [
      {
        secrets.host.token = {
          owner = "jesse";
          mode = "0404";
        };
      }
    ] (config: config.sops.secrets.token.mode);
    template = fails "sops.templates aren't supported" [
      {
        agentBroker.secrets.token = { };
        sops.templates.copy = {
          owner = "jesse";
          content = "token";
        };
      }
    ];
    name-override = fails "must keep their declared name" [
      {
        agentBroker.secrets.token = { };
        secrets.host.zhost.owner = "jesse";
        sops.secrets.zhost.name = "token";
      }
    ];
    path-override = fails "must keep their declared name" [
      {
        agentBroker.secrets.token = { };
        secrets.host.zhost.owner = "jesse";
        sops.secrets.zhost.path = "/run/secrets/token";
      }
    ];
    traversal-host = fails "secret names may use only" [
      {
        agentBroker.secrets.token = { };
        secrets.host."z/../token" = {
          owner = "jesse";
          key = "other";
        };
      }
    ];
    traversal-broker = fails "secret names may use only" [ { agentBroker.secrets."../token" = { }; } ];
    host-consumer-not-service = evalFails [
      {
        secrets.host.token = {
          owner = "jesse";
          restartUnits = [ "foo.socket" ];
        };
      }
    ] (config: config.secrets.host.token.restartUnits);
    host-consumer-guarded =
      let
        config = evaluate [
          {
            secrets.host = {
              a = {
                owner = "jesse";
                restartUnits = [ "both.service" ];
              };
              b = {
                owner = "jesse";
                restartUnits = [ "both.service" ];
              };
            };
            systemd.services.both.script = "true";
          }
        ];
      in
      lib.sort lib.lessThan config.systemd.services.both.unitConfig.ConditionPathExists == [
        "/run/secrets/a"
        "/run/secrets/b"
      ]
      && lib.elem "sops-install-secrets.service" config.systemd.services.both.after;
    jesse-in-broker-group = fails "only agent-broker may be in" [
      { users.users.jesse.extraGroups = [ "agent-broker" ]; }
    ];
  };
  broken = lib.attrNames (lib.filterAttrs (_: ok: !ok) cases);
in
assert lib.assertMsg (
  broken == [ ]
) "secret store eval cases failed: ${lib.concatStringsSep ", " broken}";
pkgs.runCommand "secret-store-eval" { } "touch $out"
