{
  config,
  lib,
  pkgs,
  ...
}:
let
  broker = config.agentBroker;
  cfg = broker.egress;
  network = "agent-sandbox";
  bridge = "br-asb";
  proxyPort = 3128;
  gateDir = broker.services.egress-gate.socketDir;
  caPath = "${broker.services.egress-proxy.socketDir}/ca.pem";
  docker = "${config.virtualisation.docker.package}/bin/docker";

  policy = {
    inherit (cfg)
      mode
      allow
      allowPrivate
      inspect
      ;
    inject = lib.mapAttrsToList (name: secret: {
      inherit name;
      inherit (secret.inject) hosts header format;
      file = secret.path;
    }) (lib.filterAttrs (_: secret: secret.inject != null) broker.secrets);
    sandbox = {
      inherit network bridge proxyPort;
      gate = "${gateDir}/control.sock";
      ca = caPath;
      group = broker.socketGroup;
      buildNetwork = if cfg.buildNetwork then "default" else "none";
      push = if broker.push.enable then broker.services.push.socketDir else null;
    };
  };

  # Docker's internal networks already drop forwarding to other interfaces, but containers can
  # still reach every host service through the bridge's gateway address.
  rules = pkgs.writeText "agent-sandbox.nft" ''
    table inet agent_sandbox
    delete table inet agent_sandbox
    table inet agent_sandbox {
      chain input {
        type filter hook input priority filter - 10; policy accept;
        iifname "${bridge}*" ct state established,related accept
        iifname "${bridge}*" counter drop
      }
      chain forward {
        type filter hook forward priority filter - 10; policy accept;
        iifname "${bridge}*" oifname != "${bridge}*" counter drop
        oifname "${bridge}*" iifname != "${bridge}*" counter drop
      }
    }
  '';
in
{
  imports = [ ./agent-push.nix ];

  options.agentBroker.egress = {
    enable = lib.mkEnableOption "the agent sandboxes' internal network, with egress only through the broker proxy";
    mode = lib.mkOption {
      type = lib.types.enum [
        "log"
        "enforce"
      ];
      default = "log";
      description = "`log` lets everything through and logs what the allowlist would deny; `enforce` denies it.";
    };
    allow = lib.mkOption {
      type = lib.types.listOf (
        lib.types.strMatching "(\\*\\.)?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:([0-9]{1,5}|\\*))?"
      );
      default = [ ];
      description = "Hosts sandboxes may reach: `host` (ports 80 and 443), `*.domain`, `host:port` or `host:*`.";
    };
    allowPrivate = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "media.lan:8096"
        "192.168.1.5:2222"
        "10.0.0.0/8:443"
        "[fd00::/8]:*"
      ];
      description = ''
        Private, LAN and CGNAT destinations sandboxes may reach through the proxy, in every mode: a
        hostname or `*.domain`, an IP address or a CIDR range (IPv6 in brackets), each with `:port`,
        `:*` or no port for 80 and 443. Link-local addresses stay refused.
      '';
    };
    inspect = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Hosts whose TLS the proxy decrypts to log paths and methods, besides those with credentials.";
    };
    buildNetwork = lib.mkOption {
      type = lib.types.bool;
      default = cfg.mode == "log";
      defaultText = lib.literalExpression ''config.agentBroker.egress.mode == "log"'';
      description = "Whether `RUN` steps in the runner's Compose builds have network, which bypasses the proxy.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.virtualisation.docker.enable;
        message = "agentBroker.egress needs Docker";
      }
    ];

    environment.etc."agent-broker/egress.json".text = builtins.toJSON policy;
    environment.systemPackages = [ pkgs.agent-egress ];

    agentBroker.services = {
      egress-proxy = {
        description = "Agent sandbox egress proxy";
        path = [ pkgs.agent-egress ];
        environment = {
          AGENT_EGRESS_PORT = toString proxyPort;
          AGENT_EGRESS_UPSTREAM_CA = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        };
        script = "exec agent-egress-proxy";
        socketDirMode = "2755";
        serviceConfig = {
          StateDirectory = "agent-broker-egress";
          StateDirectoryMode = "0711";
          # cffi's ffi.callback() needs W+X pages on Linux, and mitmproxy's TLS interception
          # always installs pyOpenSSL callbacks.
          MemoryDenyWriteExecute = false;
          Restart = "always";
          RestartSec = 2;
        };
      };
      egress-gate = {
        description = "Per-sandbox sockets in front of the egress proxy";
        path = [ pkgs.agent-egress ];
        script = ''
          exec agent-egress-gate --proxy 127.0.0.1:${toString proxyPort} --ca ${caPath} \
            --trust ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ${
              lib.concatMapStringsSep " " (user: "--client ${user}") broker.clients
            }
        '';
        # The control socket checks the peer's uid, so sessions that predate their group
        # membership can still register.
        socketDirMode = "2755";
        serviceConfig = {
          Restart = "always";
          RestartSec = 2;
        };
      };
    };

    # Without the nftables table a sandbox on the bridge reaches the host, so nothing registers.
    systemd.services.agent-broker-egress-gate = {
      after = [
        "agent-broker-egress-proxy.service"
        "agent-sandbox-netfilter.service"
      ];
      wants = [ "agent-broker-egress-proxy.service" ];
      requires = [ "agent-sandbox-netfilter.service" ];
    };

    systemd.services.agent-sandbox-netfilter = {
      description = "Drop agent sandbox traffic to the host and other networks";
      wantedBy = [ "multi-user.target" ];
      before = [ "docker.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.nftables}/bin/nft -f ${rules}";
        ExecStop = "${pkgs.nftables}/bin/nft delete table inet agent_sandbox";
      };
    };

    systemd.services.agent-sandbox-network = {
      description = "Create the agent sandboxes' internal Docker network";
      wantedBy = [ "multi-user.target" ];
      after = [
        "docker.service"
        "agent-sandbox-netfilter.service"
      ];
      requires = [
        "docker.service"
        "agent-sandbox-netfilter.service"
      ];
      script = ''
        if ! ${docker} network inspect ${network} >/dev/null 2>&1; then
          ${docker} network create --internal --driver bridge \
            --opt com.docker.network.bridge.name=${bridge} \
            --label agent-sandbox.egress=1 ${network}
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };
  };
}
