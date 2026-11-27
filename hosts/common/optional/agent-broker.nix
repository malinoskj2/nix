{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.agentBroker;
  user = "agent-broker";
  socketGroup = "agent-broker-clients";
  socketRoot = "/run/agent-broker";
  unitName = name: "agent-broker-${name}";
  brokerUnits = map (name: "${unitName name}.service") (lib.attrNames cfg.services);

  hardening = {
    User = user;
    Group = user;
    SupplementaryGroups = [ socketGroup ];
    # Sockets must be group-writable for clients to connect.
    UMask = "0007";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    RemoveIPC = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "~@resources"
    ];
  };

  secretType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        key = lib.mkOption {
          type = lib.types.strMatching "[A-Za-z0-9_-]+";
          default = name;
          description = "Top-level key holding this secret in the encrypted file.";
        };
        path = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = config.sops.secrets.${name}.path;
          description = "Where the decrypted value appears, readable by agent-broker only.";
        };
        inject = lib.mkOption {
          default = null;
          description = "How the egress proxy adds this secret to requests. Null keeps it out of the proxy.";
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                hosts = lib.mkOption {
                  type = lib.types.nonEmptyListOf lib.types.str;
                  description = "Hosts whose requests get the header.";
                };
                header = lib.mkOption {
                  type = lib.types.str;
                  default = "Authorization";
                };
                format = lib.mkOption {
                  type = lib.types.strMatching ".*\\{}.*";
                  default = "Bearer {}";
                  description = "Header value, with `{}` standing for the secret.";
                };
              };
            }
          );
        };
      };
    }
  );

  serviceType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        description = lib.mkOption { type = lib.types.str; };
        secrets = lib.mkOption {
          type = lib.types.listOf (lib.types.enum (lib.attrNames cfg.secrets));
          default = [ ];
          description = "Secrets the service reads. It doesn't start until all of them are deployed, and restarts when they change.";
        };
        path = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
        };
        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
        };
        script = lib.mkOption { type = lib.types.lines; };
        serviceConfig = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Overrides on top of the hardened defaults.";
        };
        socketDir = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = "${socketRoot}/${name}";
          description = "Directory for the service's client sockets, connectable by the agent-broker-clients group.";
        };
      };
    }
  );
in
{
  imports = [ ./secret-store.nix ];

  options.agentBroker = {
    clients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users that may connect to broker sockets.";
    };
    socketGroup = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = socketGroup;
    };
    secrets = lib.mkOption {
      type = lib.types.attrsOf secretType;
      default = { };
      description = "Secrets only agent-broker reads, for the egress proxy and broker services.";
    };
    services = lib.mkOption {
      type = lib.types.attrsOf serviceType;
      default = { };
    };
  };

  config = lib.mkMerge [
    {
      assertions =
        let
          privileged = [
            user
            config.users.groups.keys.name
          ];
          offenders = lib.filter (
            u: u.name != user && lib.any (g: lib.elem g privileged) (u.extraGroups ++ [ u.group ])
          ) (lib.attrValues config.users.users);
        in
        [
          {
            assertion = offenders == [ ] && config.users.groups.${user}.members == [ ];
            message = "only agent-broker may be in the agent-broker and keys groups; found ${
              lib.concatMapStringsSep ", " (u: u.name) offenders
            }";
          }
          {
            assertion = !lib.elem user cfg.clients;
            message = "agentBroker.clients must not include agent-broker itself";
          }
          {
            assertion =
              lib.intersectLists (lib.attrNames cfg.secrets) (lib.attrNames config.secrets.host) == [ ];
            message = "a secret is either secrets.host or agentBroker.secrets, never both: ${lib.concatStringsSep ", " (lib.intersectLists (lib.attrNames cfg.secrets) (lib.attrNames config.secrets.host))}";
          }
        ]
        ++ lib.mapAttrsToList (name: _: {
          assertion =
            let
              s = config.sops.secrets.${name};
            in
            s.owner == user
            && s.group == user
            && lib.elem s.mode [
              "0400"
              "400"
            ];
          message = "broker secret ${name} must stay agent-broker:agent-broker 0400";
        }) cfg.secrets
        ++ lib.mapAttrsToList (name: s: {
          assertion = s.owner != user && s.group != user;
          message = "host secret ${name} can't belong to agent-broker; declare it in agentBroker.secrets instead";
        }) config.secrets.host;

      users.users.${user} = {
        isSystemUser = true;
        group = user;
        home = "/var/empty";
        createHome = false;
        shell = "${pkgs.shadow}/bin/nologin";
      };
      users.groups.${user} = { };
      users.groups.${socketGroup}.members = cfg.clients;

      secrets.catalog = lib.mapAttrs (_: s: {
        kind = "broker";
        inherit (s) key path inject;
      }) cfg.secrets;
      secrets.startUnits = brokerUnits;

      systemd.tmpfiles.rules = [
        "d ${socketRoot} 0755 root root -"
      ]
      ++ lib.mapAttrsToList (_: svc: "d ${svc.socketDir} 2750 ${user} ${socketGroup} -") cfg.services;

      sops = {
        secrets = lib.mapAttrs (name: secret: {
          sopsFile = config.secrets.file;
          inherit (secret) key;
          format = "yaml";
          owner = user;
          group = user;
          mode = "0400";
          restartUnits = lib.mapAttrsToList (svc: _: "${unitName svc}.service") (
            lib.filterAttrs (_: svc: lib.elem name svc.secrets) cfg.services
          );
          # A name in both kinds fails the assertion above rather than a merge conflict.
        }) (lib.filterAttrs (name: _: !(config.secrets.host ? ${name})) cfg.secrets);
      };
    }

    {
      systemd.services = lib.mapAttrs' (
        name: svc:
        lib.nameValuePair (unitName name) {
          inherit (svc) description path script;
          environment = svc.environment // {
            AGENT_BROKER_SOCKET_DIR = svc.socketDir;
          };
          wantedBy = [ "multi-user.target" ];
          wants = lib.optional (svc.secrets != [ ]) "sops-install-secrets.service";
          after = lib.optional (svc.secrets != [ ]) "sops-install-secrets.service";
          # Undeployed secrets leave the service stopped, so it fails closed.
          unitConfig.ConditionPathExists = map (s: cfg.secrets.${s}.path) svc.secrets;
          serviceConfig = lib.mkMerge [
            (lib.mapAttrs (_: lib.mkDefault) hardening)
            {
              RuntimeDirectory = unitName name;
              RuntimeDirectoryMode = "0700";
              ReadWritePaths = [ svc.socketDir ];
            }
            svc.serviceConfig
          ];
        }
      ) cfg.services;
    }
  ];
}
