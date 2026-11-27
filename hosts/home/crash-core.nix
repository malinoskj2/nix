{ lib, pkgs, ... }:
{
  systemd.services.crash-core = {
    description = "Log the CPU core of each fatal SIGSEGV, SIGABRT, SIGBUS, SIGILL and SIGFPE";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe pkgs.nodejs-slim)
        # V8's JIT needs W+X memory, which MemoryDenyWriteExecute refuses.
        "--jitless"
        "${./crash-core.mjs}"
        (lib.getExe pkgs.bpftrace)
        "${./crash-core.bt}"
      ];
      SyslogIdentifier = "crash-core";
      Restart = "always";
      RestartSec = 5;

      CapabilityBoundingSet = [
        "CAP_BPF"
        "CAP_PERFMON"
      ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      PrivateIPC = true;
      ProtectHostname = true;
      ProtectClock = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "bpf"
        "perf_event_open"
      ];
      UMask = "0077";
      MemoryMax = "512M";
      # bpftrace raises RLIMIT_MEMLOCK at startup, which needs CAP_SYS_RESOURCE unless the hard
      # limit already allows it. BPF maps are charged to the memory cgroup instead.
      LimitMEMLOCK = "infinity";
    };
  };
}
