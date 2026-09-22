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

  # scx_lavd scores tasks by inferred latency-criticality, which suits the browser
  # and games; if it exits, the kernel falls back to its default EEVDF scheduler.
  services.scx = {
    enable = true;
    scheduler = "scx_lavd";

    # Both dies report the same cpufreq maximum, so lavd can't rank them on its own
    # and the preference has to be spelled out: the CCD0 (V-Cache) cores the agent
    # sandbox can't touch first, then the rest of CCD0, then CCD1. Values follow
    # their flags, so this list stays unsorted.
    extraArgs = [
      "--cpu-pref-order"
      "0-3,16-19,4-7,20-23,8-15,24-31"
    ];
  };

  # The "cache" mode ranks the V-Cache die first, keeping the desktop and games
  # away from the die the agent sandbox mostly runs on.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="platform", KERNEL=="AMDI0101:00", ATTR{amd_x3d_mode}="cache"
  '';
}
