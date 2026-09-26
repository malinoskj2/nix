# NVIDIA memory clock hitches

Since `home` moved from driver 595.99.02 to 615.71.09 (2026-09-19), the whole
desktop hitches when a light GPU load starts, most often when Claude Desktop
starts or stops working. The app and the Hyprland config aren't the cause.

## Cause

615 lets the RTX 5090 change its memory clock while the displays are scanning
out. Earlier drivers held it fixed with this many monitors. A trivial load
(a spinner, streaming text, one tiny CUDA kernel every 20 ms) moves it between
P8 (405 MHz), P5 (810 MHz), P3 (7001 MHz) and P1 (13801 MHz), and each switch
up stalls the GPU.

Measured on 2026-09-26 from the agent sandbox, which shares the GPU: a 1 KB
CUDA kernel that normally takes 0.1 ms took 15.3 ms and 10.8 ms at the two
810 → 13801 MHz switches, and never more than 2 ms otherwise. That's 4–5
frames at 360 Hz. The switch back down wasn't probed. Blur and Claude
Desktop's transparent window made no difference to the compositor's cost.

615 added the `RmDisableDisplayGlitchPerfLimit` token to
`NVreg_RegistryDwords`, which opts in to exactly these glitches for lower idle
power. `home` doesn't set it, but the clock switches anyway.

## Reports

- [open-gpu-kernel-modules#1391](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1391):
  615.71.09, RTX 5070 Ti, three 180 Hz monitors. Screens blank whenever the
  memory clock changes, which 610 never did.
- [NVIDIA forum](https://forums.developer.nvidia.com/t/rtx-5090-610-57-04-trivial-wayland-xwayland-rendering-triggers-excessive-p-states-memory-clocks-and-power-consumption/382477):
  RTX 5090, trivial Wayland rendering jumps to P0 / 14001 MHz before settling
  at P5 / 810 MHz.
- [615 feedback thread](https://forums.developer.nvidia.com/t/615-release-feedback-discussion/382815):
  several unrelated 615 regressions, fixed by returning to 610.

## Workarounds

| Option | Cost |
|---|---|
| Pin 595.99.02 or 610.57.04 in `hosts/home/nvidia.nix` | Loses 615's fixes |
| `nvidia-smi --lock-memory-clocks=7001,7001` | ~10 W at idle; caps memory for games and CUDA |
| Leave it | Hitches |

Power per state, measured on `home`: P8 72 W, P5 77 W, P3 87 W, P1 92 W.

## Checking a new driver

Run a light, steady GPU load and log the memory clock:

```sh
nvidia-smi --query-gpu=timestamp,pstate,clocks.mem --format=csv -lms 50
```

The driver is fixed if the memory clock stays put under the load or the
display no longer hitches when it changes.
