# Source and maintenance

This standalone limiter adapts the period/work-time pacing algorithm and Vulkan
loader link-chain handling from [MangoHud v0.8.3](https://github.com/flightlessmango/MangoHud/tree/v0.8.3),
under the included [MIT license](LICENSE):

The notices cover flightlessmango and Intel Corporation's Vulkan layer portions.

- [`src/fps_limiter.h`](https://github.com/flightlessmango/MangoHud/blob/v0.8.3/src/fps_limiter.h): compensate frame work when advancing a frame deadline.
- [`src/vulkan.cpp`](https://github.com/flightlessmango/MangoHud/blob/v0.8.3/src/vulkan.cpp): advance instance/device loader link info and forward through the appropriate dispatch table.
- [`src/gl/shim.c`](https://github.com/flightlessmango/MangoHud/blob/v0.8.3/src/gl/shim.c): OpenGL entrypoint and proc-address interposition approach.

The control receiver, interruptible wait, Steam eligibility guard and fixed
dispatch slots are local implementations. No MangoHud HUD, telemetry, config
watcher, logging or keybinding code is included or linked. There is no MangoHud
runtime dependency. Keep the upstream notice when distributing the engine.

The authoritative layer contract is the [Vulkan loader layer interface](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderLayerInterface.md).
Changes to Vulkan headers/loader, Steam runtime or graphics drivers require both
architecture checks and actual rendering through Steam's pressure-vessel runtime.
The package tests cover dispatch lifecycles and timing; they cannot establish
compatibility with every game's custom loader or anti-cheat.
