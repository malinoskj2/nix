{ pkgs, ... }:
{
  # 6.18 LTS includes sched-ext and the AMD 3D V-Cache driver, and unlike
  # linuxPackages_latest it doesn't break the NVIDIA driver on every bump.
  boot.kernelPackages = pkgs.linuxPackages_6_18;

  # amd_pstate=active keeps EPP-driven frequency control whatever the kernel's
  # default mode, and preempt=full lowers worst-case scheduling latency.
  boot.kernelParams = [
    "amd_pstate=active"
    "preempt=full"
  ];

  # scx_bpfland favors interactive tasks and knows the CCD cache topology;
  # if it exits, the kernel falls back to its default EEVDF scheduler.
  services.scx = {
    enable = true;
    scheduler = "scx_bpfland";

    # -m performance prefers the fastest cores; -S keeps high-wakeup tasks on their CPU
    # for cache locality. Values follow their flags, so this list stays unsorted.
    extraArgs = [
      "-m"
      "performance"
      "-S"
    ];
  };

  # The "frequency" mode ranks the high-frequency CCD1 first for desktop work;
  # the "cache" mode ranks the V-Cache die first instead, which suits games.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="platform", KERNEL=="AMDI0101:00", ATTR{amd_x3d_mode}="frequency"
  '';
}
