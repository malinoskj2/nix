{
  config,
  inputs,
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
  declaredKeys = lib.mapAttrsToList (_: secret: secret.key) cfg.secrets;

  # sops keeps key names in plaintext, so presence is checked without decrypting.
  secretsReady = pkgs.writeShellApplication {
    name = "agent-secrets-ready";
    runtimeInputs = [ pkgs.yq-go ];
    text = ''
      file=${lib.escapeShellArg cfg.secretsFile}
      key=${lib.escapeShellArg cfg.keyFile}
      if [[ ! -s $key ]]; then
        echo "agent secrets: no decryption key at $key; broker secrets stay undeployed" >&2
        exit 1
      fi
      if [[ ! -s $file ]]; then
        echo "agent secrets: no encrypted file at $file; broker secrets stay undeployed" >&2
        exit 1
      fi
      missing=()
      for name in ${lib.escapeShellArgs declaredKeys}; do
        if ! NAME=$name yq -e 'has(strenv(NAME))' "$file" >/dev/null 2>&1; then
          missing+=("$name")
        fi
      done
      if ((''${#missing[@]})); then
        echo "agent secrets: $file lacks ''${missing[*]}; broker secrets stay undeployed" >&2
        exit 1
      fi
    '';
  };

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
  imports = [ inputs.sops-nix.nixosModules.sops ];

  options.agentBroker = {
    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agent-secrets/secrets.yaml";
      description = "The host's sops-encrypted secrets. It lives outside every repository and the store.";
    };
    keyFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sops-nix/key.txt";
      description = "The host's root-only age identity.";
    };
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
        ];

      users.users.${user} = {
        isSystemUser = true;
        group = user;
        home = "/var/empty";
        createHome = false;
        shell = "${pkgs.shadow}/bin/nologin";
      };
      users.groups.${user} = { };
      users.groups.${socketGroup}.members = cfg.clients;

      environment.systemPackages = [ pkgs.agent-secret ];
      environment.etc."agent-secrets/config.json".text = builtins.toJSON {
        inherit (cfg) secretsFile keyFile;
        secrets = lib.mapAttrs (_: s: { inherit (s) key path inject; }) cfg.secrets;
        services = map (name: "${unitName name}.service") (lib.attrNames cfg.services);
      };

      systemd.tmpfiles.rules = [
        "d ${dirOf cfg.secretsFile} 0700 root root -"
        "d ${dirOf cfg.keyFile} 0700 root root -"
        "d ${socketRoot} 0755 root root -"
      ]
      ++ lib.mapAttrsToList (_: svc: "d ${svc.socketDir} 2750 ${user} ${socketGroup} -") cfg.services;

      sops = {
        age.keyFile = cfg.keyFile;
        age.sshKeyPaths = [ ];
        gnupg.sshKeyPaths = [ ];
        # The encrypted file lives on the host, outside the flake and the store.
        validateSopsFiles = false;
        useSystemdActivation = true;
        secrets = lib.mapAttrs (name: secret: {
          sopsFile = cfg.secretsFile;
          inherit (secret) key;
          format = "yaml";
          owner = user;
          group = user;
          mode = "0400";
          restartUnits = lib.mapAttrsToList (svc: _: "${unitName svc}.service") (
            lib.filterAttrs (_: svc: lib.elem name svc.secrets) cfg.services
          );
        }) cfg.secrets;
      };
    }

    (lib.mkIf (cfg.secrets != { }) {
      # A missing key, file or declared secret skips deployment instead of failing the switch.
      systemd.services.sops-install-secrets.serviceConfig.ExecCondition = lib.getExe secretsReady;
    })

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
