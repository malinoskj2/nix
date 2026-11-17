{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.resourceScheduler;
  policy = pkgs.writeText "resource-scheduler.json" (
    builtins.toJSON {
      socket_path = "/run/resource-scheduler/control.sock";
      state_dir = "/var/lib/resource-scheduler";
      allowed_uid = cfg.ownerUid;
      allowed_gid = cfg.ownerGid;
      partition = "resource";
      cpu_capacity = cfg.cpuCapacity;
      game_cpu_capacity = cfg.gameCpuCapacity;
      game_marker_path = "/run/resource-scheduler-game-active";
      adaptive_ram = cfg.adaptiveRam;
      large_gpu_lane = cfg.largeGpuLane;
      large_lane_project_ids = cfg.largeLaneProjectIds;
      ram_capacity_mib = cfg.memoryMiB;
      ram_headroom_mib = cfg.ramHeadroomMiB;
      vram_headroom_mib = cfg.vramHeadroomMiB;
      gpu_capacity_mib = cfg.gpuCapacityMiB;
      poll_seconds = 2;
      stability_seconds = cfg.stabilitySeconds;
      history_limit = 500;
      policy_version = cfg.policyVersion;
    }
  );
in
{
  options.services.resourceScheduler = {
    enable = lib.mkEnableOption "the shared workstation resource scheduler (requires a drained GPU cutover)";
    package = lib.mkPackageOption pkgs "resource-scheduler" { };
    ownerUid = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1000;
      description = "Only this Unix UID may submit or control jobs over the local socket.";
    };
    ownerGid = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 100;
      description = "Primary GID used after the trusted Slurm bootstrap drops privileges.";
    };
    nodeName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Single local Slurm execution node.";
    };
    cpuCapacity = lib.mkOption {
      type = lib.types.ints.positive;
      default = 12;
      description = "Normal admission ceiling in Slurm CPU units (SMT/core rounding applies).";
    };
    gameCpuCapacity = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Aggregate background CPU quota and admission ceiling during managed or external games; excludes the game allocation.";
    };
    memoryMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24576;
      description = "Static Slurm RAM ceiling, not dynamically available host memory.";
    };
    largeGpuLane = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Experimental managed large-GPU lane outside Slurm accounting; retains CPU/RAM limits and critical pressure/headroom gates.";
    };
    largeLaneProjectIds = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[1-9][0-9]{0,38}");
      default = [ ];
      description = "Numeric project fingerprints automatically sharing the single managed lane, including CPU-only submissions and probes. Explicit strict memory remains excluded.";
    };
    adaptiveRam = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use measured growth allowances after startup for adaptive jobs; preserves Slurm RAM limits but permits host memory overcommit risk.";
    };
    ramHeadroomMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
      description = "Additional available host RAM retained beyond outstanding reservations.";
    };
    vramHeadroomMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3072;
      description = "Additional VRAM retained beyond observed external device use.";
    };
    gpuCapacityMiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 32768;
      description = "Single-device cooperative VRAM shard pool ceiling; admission additionally uses measured free VRAM.";
    };
    stabilitySeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Stable headroom interval before new admissions resume after pressure.";
    };
    policyVersion = lib.mkOption {
      type = lib.types.str;
      default = "1";
      description = "Reviewed policy version recorded in status and events; bump when changing policy or headroom tuning.";
    };
    mungeKey = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/munge/munge.key";
      description = "Host-only Munge key, generated at first service start outside the Nix store.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.gameCpuCapacity <= cfg.cpuCapacity;
        message = "resourceScheduler.gameCpuCapacity must not exceed the normal CPU admission ceiling.";
      }
      {
        assertion = cfg.vramHeadroomMiB < cfg.gpuCapacityMiB;
        message = "resourceScheduler VRAM headroom must leave a positive cooperative GPU pool.";
      }
    ];
    # Host launchers, Steam and sandbox images all resolve the same adapter.
    # This replaces legacy admission after the mode marker is deployed.
    nixpkgs.overlays = lib.mkAfter [
      (_final: prev: {
        gpu-scheduler = prev.gpu-scheduler.override { unifiedScheduler = cfg.package; };
      })
    ];
    environment.systemPackages = [ cfg.package ];
    environment.etc = {
      "resource-scheduler/config.json".source = policy;
      "resource-scheduler/mode".text = "slurm\n";
    };
    # Slurm's advertised loopback address does not guarantee a loopback bind.
    # Limit only its RPC ports, preserving job/container networking.
    networking.nftables = {
      enable = true;
      tables.resource-scheduler = {
        family = "inet";
        content = ''
          chain local_rpc {
            type filter hook input priority -10; policy accept;
            iifname != "lo" tcp dport { 6817, 6818 } drop
          }
        '';
      };
    };

    services.slurm = {
      server.enable = true;
      server.flags.systemd = true;
      client.enable = true;
      clusterName = "workstation-resources";
      procTrackType = "proctrack/cgroup";
      nodeName = [
        "${cfg.nodeName} NodeAddr=127.0.0.1 NodeHostName=${cfg.nodeName} CPUs=32 Boards=1 SocketsPerBoard=1 CoresPerSocket=16 ThreadsPerCore=2 RealMemory=${toString cfg.memoryMiB} Gres=gpu:1,shard:${toString cfg.gpuCapacityMiB} State=UNKNOWN"
      ];
      partitionName = [
        "resource Nodes=${cfg.nodeName} Default=YES RootOnly=YES AllowGroups=root MaxTime=INFINITE MaxCPUsPerNode=${toString cfg.cpuCapacity} OverSubscribe=NO State=UP"
      ];
      extraConfig = ''
        SlurmctldHost=${cfg.nodeName}(127.0.0.1)
        AuthType=auth/munge
        CredType=cred/munge
        SlurmdUser=root
        SlurmctldPort=6817
        SlurmdPort=6818
        SlurmdSpoolDir=/var/spool/slurmd
        SelectType=select/cons_tres
        EnforcePartLimits=ALL
        SelectTypeParameters=CR_Core_Memory
        GresTypes=gpu,shard
        TaskPlugin=task/cgroup
        JobAcctGatherType=jobacct_gather/cgroup
        JobAcctGatherFrequency=task=10
        SchedulerType=sched/backfill
        SchedulerParameters=bf_continue
        ReturnToService=1
        SlurmctldDebug=info
        SlurmdDebug=info
        JobCompType=jobcomp/filetxt
        JobCompLoc=/var/lib/slurm-job-completions/jobs
      '';
      extraConfigPaths = [
        (pkgs.writeTextDir "gres.conf" ''
          Name=gpu File=/dev/nvidia0
          Name=shard Count=${toString cfg.gpuCapacityMiB} File=/dev/nvidia0
        '')
      ];
      extraCgroupConfig = ''
        CgroupPlugin=cgroup/v2
        EnableControllers=yes
        ConstrainCores=yes
        ConstrainRAMSpace=yes
        ConstrainSwapSpace=yes
        AllowedSwapSpace=0
        ConstrainDevices=yes
      '';
    };

    services.munge = {
      enable = true;
      password = cfg.mungeKey;
    };
    # Never put an authentication secret in an evaluation/build result.
    systemd.services.resource-scheduler-munge-key = {
      description = "Create the local Slurm authentication key if missing";
      before = [ "munged.service" ];
      requiredBy = [ "munged.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        if ! test -e ${lib.escapeShellArg cfg.mungeKey}; then
          install -d -m 0700 -o munge -g munge ${lib.escapeShellArg (builtins.dirOf cfg.mungeKey)}
          ${pkgs.munge}/bin/mungekey --create --keyfile=${lib.escapeShellArg cfg.mungeKey}
          chown munge:munge ${lib.escapeShellArg cfg.mungeKey}
          chmod 0400 ${lib.escapeShellArg cfg.mungeKey}
        fi
      '';
      path = [ pkgs.coreutils ];
    };
    systemd.services.munged.after = [ "resource-scheduler-munge-key.service" ];
    # The upstream module refers to munge.service for slurmd, but the service is munged.
    systemd.services.slurmd = {
      environment.SLURM_CONF = "${config.services.slurm.etcSlurm}/slurm.conf";
      requires = [ "munged.service" ];
      wants = [ "network-online.target" ];
      after = [
        "munged.service"
        "network-online.target"
      ];
      serviceConfig = {
        Type = lib.mkForce "notify";
        ExecStart = lib.mkForce "${config.services.slurm.package}/bin/slurmd --systemd";
        PIDFile = lib.mkForce null;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
    # Listener address resolution can fail during boot. Keep both daemons
    # retrying after network readiness rather than leaving the queue offline.
    # A SIGHUP reconfigure re-executes the daemon and the old process exits 0;
    # under Type=forking systemd then stops the unit and kills the new process.
    systemd.services.slurmctld = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = lib.mkForce "notify";
        PIDFile = lib.mkForce null;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/slurm-job-completions 0700 slurm slurm -"
    ];
    services.logrotate.settings.resource-slurm-completions = {
      files = [ "/var/lib/slurm-job-completions/jobs" ];
      frequency = "daily";
      rotate = 30;
      maxsize = "32M";
      compress = true;
      missingok = true;
      notifempty = true;
      create = "0600 slurm slurm";
      postrotate = "${config.systemd.package}/bin/systemctl reload slurmctld.service || true";
    };

    systemd.services.resource-scheduler = {
      description = "Shared Slurm resource admission and telemetry API";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "slurmctld.service"
        "slurmd.service"
      ];
      after = [
        "slurmctld.service"
        "slurmd.service"
      ];
      path = [
        config.services.slurm.package
        pkgs.docker
        pkgs.util-linux
        pkgs.coreutils
      ];
      environment = {
        SLURM_CONF = "${config.services.slurm.etcSlurm}/slurm.conf";
        PATH = lib.mkForce (
          lib.makeBinPath [
            config.services.slurm.package
            pkgs.docker
            pkgs.util-linux
            pkgs.coreutils
          ]
          + ":/run/opengl-driver/bin"
        );
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/resource-scheduler daemon --config ${policy}";
        User = "root";
        Group = "root";
        UMask = "0077";
        StateDirectory = "resource-scheduler";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "resource-scheduler";
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = "yes";
        Restart = "on-failure";
        RestartSec = 3;
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "resource-scheduler";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        LockPersonality = true;
        RestrictRealtime = true;
        # Do not use PrivateTmp/PrivateUsers, hide /proc, or remove CAP_SYS_ADMIN:
        # the audited bootstrap must enter the submitting container's namespaces.
      };
    };

    # Shared host retention is explicit and bounded; authoritative Slurm state is
    # held in /var/spool/slurmctld, never reconstructed from the journal.
    services.journald.extraConfig = ''
      Storage=persistent
      SystemMaxUse=1G
      SystemKeepFree=2G
      MaxRetentionSec=30day
      MaxFileSec=1day
    '';
  };
}
