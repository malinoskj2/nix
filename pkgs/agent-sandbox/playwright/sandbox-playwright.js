"use strict";

const { spawnSync } = require("node:child_process");

const gpuArgs = @gpuArgs@;

let gpu;
function gpuAvailable() {
  if (gpu === undefined) {
    gpu = spawnSync("@probe@", { stdio: "ignore" }).status === 0;
    if (!gpu) {
      process.emitWarning(
        "no Vulkan GPU found, so Chromium falls back to SwiftShader: expect slow WebGL frames, ReadPixels stalls and delayed input",
        { code: "SANDBOX_PLAYWRIGHT_NO_GPU" },
      );
    }
  }
  return gpu;
}

// The default headless shell always renders with SwiftShader. The "chromium" channel runs the
// full browser in new headless mode, which can use ANGLE's Vulkan backend without a display.
// Chromium only reads proxy variables when no desktop names its own settings, so pass the
// egress proxy explicitly.
function proxyOption() {
  const server = process.env.HTTPS_PROXY;
  return server ? { proxy: { server, bypass: process.env.NO_PROXY ?? "" } } : {};
}

function chromiumLaunchOptions(options = {}) {
  return {
    channel: "chromium",
    ...proxyOption(),
    ...options,
    args: [...(gpuAvailable() ? gpuArgs : []), ...(options.args ?? [])],
  };
}

function chromiumWith(playwright = require("playwright")) {
  const { chromium } = playwright;
  return {
    launch: (options) => chromium.launch(chromiumLaunchOptions(options)),
    launchPersistentContext: (userDataDir, options) =>
      chromium.launchPersistentContext(userDataDir, chromiumLaunchOptions(options)),
  };
}

module.exports = {
  gpuArgs,
  gpuAvailable,
  chromiumLaunchOptions,
  chromiumWith,
  get chromium() {
    return chromiumWith();
  },
  get use() {
    const { channel, args, proxy } = chromiumLaunchOptions();
    return { channel, launchOptions: { args }, ...(proxy ? { proxy } : {}) };
  },
};
