{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.secrets;
  helper = cfg.unlock.helper;
  pamExec = "${config.security.pam.package}/lib/security/pam_exec.so";
  manifest = config.system.build.sops-nix-manifest;
  storeSecrets = lib.filterAttrs (_: s: s.sopsFile == cfg.file) config.sops.secrets;
  keys = lib.mapAttrsToList (_: s: s.key) storeSecrets;
  # sops-install-secrets joins the name onto /run/secrets, so it must stay one plain component.
  badNames = lib.filter (name: builtins.match "[A-Za-z0-9_-]+" name == null) (
    lib.attrNames storeSecrets
  );
  noncanonical = lib.attrNames (
    lib.filterAttrs (name: s: s.name != name || s.path != "/run/secrets/${name}") storeSecrets
  );
  # Each host consumer waits for every secret that names it.
  hostConsumers = lib.zipAttrs (
    lib.concatLists (
      lib.mapAttrsToList (
        _: s: map (unit: { ${lib.removeSuffix ".service" unit} = s.path; }) s.restartUnits
      ) cfg.host
    )
  );

  withdrawLib = ''
    manifest=${manifest}
    file=${lib.escapeShellArg cfg.file}

    # Deletes the named secrets from every sops-nix generation and stops their consumers.
    withdraw() {
      local names name unit
      names=$(printf '%s\n' "$@" | jq -R . | jq -cs .)
      while read -r unit; do
        # --no-block: consumers are ordered after this unit, whose job is still running.
        systemctl stop --no-block "$unit" || true
      done < <(jq -r --argjson names "$names" \
        '[.secrets[] | select(.name as $n | $names | index($n)) | .restartUnits[]] | unique[]' "$manifest")
      for name in "$@"; do
        rm -f -- /run/secrets.d/*/"$name"
      done
    }

    store_names() {
      jq -r --arg file "$file" '.secrets[] | select(.sopsFile == $file) | .name' "$manifest"
    }
  '';

  # A missing key or file withdraws every secret and skips deployment, instead of failing the switch.
  storeReady = pkgs.writeShellApplication {
    name = "secrets-ready";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      config.systemd.package
    ];
    text = ''
      ${withdrawLib}
      key=${lib.escapeShellArg cfg.keyFile}
      problem=
      [[ -s $key ]] || problem="no decryption key at $key"
      [[ -s $file ]] || problem="no encrypted file at $file"
      if [[ -n $problem ]]; then
        echo "secrets: $problem; every secret is withdrawn and its consumers stopped" >&2
        mapfile -t names < <(store_names)
        withdraw "''${names[@]}"
        exit 1
      fi
    '';
  };

  # sops keeps key names in plaintext, so this finds the declared secrets missing
  # from the file without decrypting it, and deploys the rest.
  install = pkgs.writeShellApplication {
    name = "secrets-install";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.yq-go
      config.systemd.package
    ];
    text = ''
      ${withdrawLib}
      present=$(yq -o json 'keys' "$file")
      mapfile -t missing < <(jq -r --arg file "$file" --argjson present "$present" \
        '.secrets[] | select(.sopsFile == $file and (.key as $k | $present | index($k) | not)) | .name' "$manifest")
      if ((''${#missing[@]})); then
        echo "secrets: $file lacks ''${missing[*]}; only they stay undeployed, and their consumers stopped" >&2
        withdraw "''${missing[@]}"
      fi
      dir=$(mktemp -d /run/secrets-manifest.XXXXXX)
      trap 'rm -rf "$dir"' EXIT
      jq --arg file "$file" --argjson present "$present" \
        '.secrets |= map(select(.sopsFile != $file or (.key as $k | $present | index($k))))' \
        "$manifest" >"$dir/manifest.json"
      ${config.sops.package}/bin/sops-install-secrets "$dir/manifest.json"
    '';
  };

  hostSecretType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        key = lib.mkOption {
          type = lib.types.strMatching "[A-Za-z0-9_-]+";
          default = name;
          description = "Top-level key holding this secret in the encrypted file.";
        };
        owner = lib.mkOption {
          type = lib.types.str;
          description = "User the decrypted file belongs to.";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "root";
        };
        mode = lib.mkOption {
          type = lib.types.strMatching "0?[0-7][0-7]0";
          default = "0400";
          description = "File mode; other users never get access.";
        };
        restartUnits = lib.mkOption {
          type = lib.types.listOf (lib.types.strMatching ".+\\.service");
          default = [ ];
          description = "Services that read the secret. They start only once every secret naming them is deployed, restart when one changes, and stop when one is withdrawn.";
        };
        path = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          default = config.sops.secrets.${name}.path;
          description = "Where the decrypted value appears.";
        };
      };
    }
  );
in
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  options.secrets = {
    file = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/secrets/secrets.yaml";
      description = "The host's sops-encrypted secrets. It lives outside every repository and the store.";
    };
    keyFile = lib.mkOption {
      type = lib.types.str;
      default = if cfg.unlock.enable then "/run/secrets-key/key.txt" else "/var/lib/sops-nix/key.txt";
      defaultText = lib.literalMD "on a ramfs while unlocked, or `/var/lib/sops-nix/key.txt` without `unlock`";
      description = "The host's root-only age identity.";
    };
    unlock = {
      enable = lib.mkEnableOption "keeping the host key wrapped with a user's login password, unwrapped at login";
      user = lib.mkOption {
        type = lib.types.str;
        description = "User whose login password wraps the key.";
      };
      helper = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${pkgs.secret}/bin/secret-unlock";
      };
      sealedKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/sops-nix/key.sealed";
      };
      pamServices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "greetd"
          "login"
        ];
        description = "Login services whose password unlocks the key. Screen lockers, sudo and SSH stay out.";
      };
    };
    host = lib.mkOption {
      type = lib.types.attrsOf hostSecretType;
      default = { };
      description = "Secrets for host users and services, decrypted to /run/secrets/<name>.";
    };
    catalog = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      internal = true;
      default = { };
      description = "Each declared secret's kind and non-secret settings, for the secret CLI.";
    };
    startUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      internal = true;
      default = [ ];
      description = "Units to start after a deployment, since a missing secret may have kept them stopped.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          # A template can copy any secret's value to a file with another owner,
          # and withdrawal doesn't track rendered files.
          assertion = config.sops.templates == { };
          message = "sops.templates aren't supported with the secret store: they can copy a secret to another owner";
        }
        {
          assertion = badNames == [ ];
          message = "secret names may use only letters, digits, - and _: ${lib.concatStringsSep ", " badNames}";
        }
        {
          assertion = noncanonical == [ ];
          message = "secrets in ${cfg.file} must keep their declared name and /run/secrets/<name> path; overridden: ${lib.concatStringsSep ", " noncanonical}";
        }
        {
          assertion = lib.allUnique keys;
          message = "secrets: each key in ${cfg.file} has exactly one consumer kind, but these share keys: ${lib.concatStringsSep ", " (lib.attrNames storeSecrets)}";
        }
      ];

      secrets.catalog = lib.mapAttrs (_: s: {
        kind = "host";
        inherit (s)
          key
          path
          owner
          group
          mode
          ;
      }) cfg.host;

      secrets.startUnits = lib.concatMap (s: s.restartUnits) (lib.attrValues cfg.host);

      systemd.services = lib.mapAttrs (_: paths: {
        wants = [ "sops-install-secrets.service" ];
        after = [ "sops-install-secrets.service" ];
        unitConfig.ConditionPathExists = paths;
      }) hostConsumers;

      environment.systemPackages = [ pkgs.secret ];
      environment.etc."secrets/config.json".text = builtins.toJSON {
        inherit (cfg) file keyFile;
        unlock = {
          inherit (cfg.unlock) enable sealedKeyFile helper;
          user = if cfg.unlock.enable then cfg.unlock.user else null;
          systemdCreds = "${config.systemd.package}/bin/systemd-creds";
          systemctl = "${config.systemd.package}/bin/systemctl";
          systemdRun = "${config.systemd.package}/bin/systemd-run";
          libcrypt = "${pkgs.libxcrypt}/lib/libcrypt.so.2";
        };
        secrets = cfg.catalog;
        units = lib.unique cfg.startUnits;
      };

      systemd.tmpfiles.rules = [
        "d ${dirOf cfg.file} 0700 root root -"
        "d ${dirOf cfg.keyFile} 0700 root root -"
      ];

      sops = {
        age.keyFile = cfg.keyFile;
        age.sshKeyPaths = [ ];
        gnupg.sshKeyPaths = [ ];
        # The encrypted file lives on the host, outside the flake and the store.
        validateSopsFiles = false;
        useSystemdActivation = true;
        secrets = lib.mapAttrs (_: s: {
          sopsFile = cfg.file;
          format = "yaml";
          inherit (s)
            key
            owner
            group
            mode
            restartUnits
            ;
        }) cfg.host;
      };
    }

    (lib.mkIf (storeSecrets != { }) {
      systemd.services.sops-install-secrets = {
        path = [ config.systemd.package ];
        serviceConfig = {
          ExecCondition = lib.getExe storeReady;
          ExecStart = lib.mkForce [ (lib.getExe install) ];
        };
        # secret apply restarts it on demand.
        unitConfig.StartLimitIntervalSec = 0;
      };
    })

    (lib.mkIf cfg.unlock.enable {
      assertions = [
        {
          assertion = lib.hasPrefix "/run/" cfg.keyFile;
          message = "secrets.unlock keeps the unwrapped key in memory, so secrets.keyFile must be under /run";
        }
      ];

      # ramfs never swaps, unlike tmpfs.
      systemd.mounts = [
        {
          what = "ramfs";
          where = dirOf cfg.keyFile;
          type = "ramfs";
          options = "mode=0700";
          wantedBy = [ "local-fs.target" ];
        }
      ];
      systemd.tmpfiles.rules = [ "d ${dirOf cfg.unlock.sealedKeyFile} 0700 root root -" ];

      systemd.services.secrets-apply = {
        description = "Deploy secrets after the host key is unlocked";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.secret} apply";
        };
      };

      security.pam.services = lib.mkMerge (
        map (service: {
          ${service}.rules = {
            # Stages the unwrapped key: before pam_unix, which ends the stack on success.
            auth.secrets-unlock = {
              order = config.security.pam.services.${service}.rules.auth.unix.order - 10;
              control = "optional";
              modulePath = pamExec;
              args = [
                "expose_authtok"
                "quiet"
                "seteuid"
                helper
                "pam"
              ];
            };
            # The session stack only runs for a login that passed authentication and the account checks.
            session.secrets-unlock = {
              order = config.security.pam.services.${service}.rules.session.unix.order + 10;
              control = "optional";
              modulePath = pamExec;
              args = [
                "quiet"
                "seteuid"
                "type=open_session"
                helper
                "pam"
              ];
            };
          };
        }) cfg.unlock.pamServices
        ++
          map
            (service: {
              ${service}.rules.password = {
                # pam_unix is the stack's only module, so required means the same as sufficient,
                # except that the rewrap still runs after it; it checks the shadow file itself.
                unix.control = lib.mkForce "required";
                secrets-rewrap = {
                  order = config.security.pam.services.${service}.rules.password.unix.order + 10;
                  control = "optional";
                  modulePath = pamExec;
                  args = [
                    "expose_authtok"
                    "quiet"
                    "seteuid"
                    helper
                    "pam"
                  ];
                };
              };
            })
            [
              "passwd"
              "chpasswd"
            ]
      );
    })
  ];
}
