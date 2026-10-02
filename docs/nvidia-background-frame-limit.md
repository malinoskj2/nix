# NVIDIA driver background frame limiting

Checked on 2026-10-01: there is no supported NVIDIA Linux driver setting that
replaces our automatic limiter with the same behavior: Steam games at 10 FPS
when unfocused, uncapped when focused. Keep the existing controller and
presentation hooks. This is a capability investigation, not a game benchmark.

`hosts/home/nvidia.nix` pins 615.71.09 with open kernel modules;
`nvidia-smi --query-gpu=name,driver_version --format=csv,noheader` also reported
an RTX 5090 running 615.71.09. `nvidiaSettings = false` means the control panel
is disabled, but enabling it would not add the missing driver capability.

## Why the settings do not replace our limiter

- The Windows observation is correct: NVIDIA App's
  [release notes](https://www.nvidia.com/en-us/software/nvidia-app/release-highlights/)
  list Background Application Max Frame Rate among settings migrated from
  Control Panel. NVIDIA's [settings reference](https://www.nvidia.com/content/Control-Panel-Help/vLatest/en-us/mergedProjects/3D%20Settings/Manage_3D_Settings_(reference).htm)
  distinguishes **Max Frame Rate** (a general cap, 20–1000 FPS) from
  **Background Application Max Frame Rate** (background only, 20–200 FPS).
  That Windows control is not exposed by the Linux settings examined here,
  and its documented range does not include our 10 FPS target.
- The installed driver's `share/nvidia/nvidia-application-profiles-key-documentation`
  contains 26 keys, none mentioning frames, FPS, background state or focus.
  The [615.71.09 profile documentation](https://download.nvidia.com/XFree86/Linux-x86_64/615.71.09/README/profiles.html)
  describes matching process attributes when the driver loads; its predicates
  do not include focus or workspace. Rewriting profiles on a workspace change
  is therefore not a documented live control for an already running game.
- The release's [NV-CONTROL header](https://github.com/NVIDIA/nvidia-settings/blob/615.71.09/src/libXNVCtrl/NVCtrl.h)
  exposes no background FPS or configurable FPS limit attribute. Its
  `SyncToVBlank` control applies to newly started OpenGL clients; vblank sync
  is not a 10 FPS focus-sensitive cap.
- [`LimitFrameRateWhenHeadless`](https://download.nvidia.com/XFree86/Linux-x86_64/615.71.09/README/xconfigoptions.html)
  is an X-driver option for vblank-synchronized applications when there are
  no active displays, with a 1 FPS limit. Leaving a workspace does not make
  the desktop headless, and this is not a per-game focus control.

## Vulkan and Proton

[DXVK](https://github.com/doitsujin/dxvk) and
[vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton) translate
Direct3D to Vulkan. Using XWayland for a window does not turn Vulkan rendering
into OpenGL, so OpenGL configuration alone cannot cover those games.

The installed `libnvidia-api.so.1` was also checked directly. Initialization
succeeded, but the driver returned no function for any of the DRS session,
get-setting, set-setting or save-settings interfaces below. Their IDs come
from NVIDIA's [NVAPI interface definitions](https://github.com/NVIDIA/nvapi/blob/main/nvapi_interface.h).

`DXVK_NVAPI_DRS_SETTINGS` is not a substitute:
[DXVK-NVAPI's implementation](https://github.com/jp7677/dxvk-nvapi/blob/0f26995d8126617d4d99f62c9571715fc7765da1/src/nvapi_drs.cpp)
returns environment-supplied values when an application asks for settings;
`NvAPI_DRS_SetSetting` and `NvAPI_DRS_SaveSettings` return `NotSupported`.
Supplying a Windows frame-limiter setting ID therefore does not install a
Linux driver presentation limiter.

## Online follow-up

Additional searches covered Linux driver FPS caps, background caps, recent
615 changes and Proton NVAPI settings. No supported equivalent was found.
The [615 release announcement](https://forums.developer.nvidia.com/t/615-release-feedback-discussion/382815)
adds Vulkan Reflex support and fixes Smooth Motion hangs; it does not
announce a background cap. NVIDIA's [Linux gaming guide](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/gaming.html)
documents Smooth Motion, DLSS overrides and application-integrated Reflex,
without providing a focus-sensitive FPS switch.

Common search results refer to different mechanisms:

- `__GL_MaxFramesAllowed` controls queued OpenGL frames. The original
  [KWin change](https://phabricator.kde.org/D19867), with an explanation by its
  author, describes limiting the queue in `glXSwapBuffers`. Setting it to
  `1` does not mean 1 FPS; it supplies no FPS target or focus condition.
- [MangoHud](https://github.com/flightlessmango/MangoHud/blob/master/README.md)
  has a real `fps_limit`; its [limiter source](https://github.com/flightlessmango/MangoHud/blob/master/src/fps_limiter.h)
  implements sleeping in the layer. [Goverlay](https://github.com/benjamimgois/goverlay)
  configures MangoHud and other tools. These can expose per-game settings
  through a GUI, but they are not NVIDIA driver controls.
- [libstrangle](https://github.com/milaq/libstrangle) implements an OpenGL
  cap through `LD_PRELOAD`. [DXVK's configuration](https://github.com/doitsujin/dxvk/blob/master/dxvk.conf)
  also has frame-rate settings inside the translation library. Neither
  mechanism establishes an automatic NVIDIA background cap.

The Windows setting IDs in NVAPI headers and working Proton DLSS overrides
do not establish support for arbitrary Windows driver features on Linux.
The DRS implementation and installed-driver probe above are the deciding
evidence for that route.

## Rechecking after a driver upgrade

Inspect the new driver package's profile key documentation and NV-CONTROL
header for an FPS cap with automatic focus handling or live per-process
control. This read-only probe checks the Linux NVAPI route without changing
settings:

```python
import ctypes

driver = ctypes.CDLL("/run/opengl-driver/lib/libnvidia-api.so.1")
query = driver.nvapi_QueryInterface
query.argtypes = [ctypes.c_uint32]
query.restype = ctypes.c_void_p
initialize = ctypes.CFUNCTYPE(ctypes.c_int)(query(0x0150e828))
print("Initialize:", initialize())
for name, identifier in {
    "DRS_CreateSession": 0x0694d52e,
    "DRS_GetSetting": 0x73bf8338,
    "DRS_SetSetting": 0x577dd202,
    "DRS_SaveSettings": 0xfcbc7e14,
}.items():
    print(name, bool(query(identifier)))
```

615.71.09 returned `Initialize: 0` and `False` for all four interfaces.
These checks rule out the supported settings examined, not undisclosed
internal driver options. Replacing the current limiter would still require
measuring focus transitions and frame rates in a real game. The separate
XWayland versus Wine Wayland comparison remains deferred.
