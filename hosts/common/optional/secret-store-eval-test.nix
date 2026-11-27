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
