# CPU scheduler + Ryzen 9 9950X3D dual-CCD tuning
{ pkgs, ... }:

{
  # Latest mainline kernel: ships sched-ext (CONFIG_SCHED_CLASS_EXT) and the
  # AMD 3D V-Cache optimizer, no out-of-tree kernel needed.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # sched-ext userspace scheduler. scx_bpfland prioritizes interactive tasks
  # and is CCD-cache aware — keeps the desktop responsive under load. If the
  # scheduler ever dies the kernel transparently falls back to EEVDF.
  services.scx = {
    enable = true;
    scheduler = "scx_bpfland";
    # -m performance: bias tasks onto the fastest cores (still spills to all
    # cores under multithreaded load). -S: pin high-wakeup tasks to their CPU
    # to cut runqueue lock contention and keep cache/CCD locality.
    extraArgs = [ "-m" "performance" "-S" ];
  };

  # amd_pstate active EPP is the running default; pin it explicitly.
  # preempt=full: switch PREEMPT_DYNAMIC to full preemption for lower
  # worst-case scheduling latency.
  boot.kernelParams = [ "amd_pstate=active" "preempt=full" ];

  # AMD 3D V-Cache Optimizer (amd_x3d_vcache). Bias the scheduler's
  # preferred-core ranking toward the high-frequency CCD1 — best for general
  # desktop/productivity. Switch to "cache" to favor the V-cache die for
  # latency-bound work (games).
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="platform", KERNEL=="AMDI0101:00", ATTR{amd_x3d_mode}="frequency"
  '';
}
