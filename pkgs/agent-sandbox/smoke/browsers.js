"use strict";

// Usage: node browsers.js <video file>. Prints one JSON line per check and exits nonzero on failure.
const { pathToFileURL } = require("node:url");
const playwright = require("playwright");
const { chromium } = require("sandbox-playwright");

const video = process.argv[2];
let failed = false;

function report(name, ok, detail) {
  failed ||= !ok;
  console.log(JSON.stringify({ check: name, ok, detail }));
}

async function webgl() {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    await page.setContent("<canvas id=c></canvas>");
    const renderer = await page.evaluate(() => {
      const gl = document.getElementById("c").getContext("webgl2") ?? document.getElementById("c").getContext("webgl");
      if (!gl) return null;
      const info = gl.getExtension("WEBGL_debug_renderer_info");
      return info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
    });
    const gpu = typeof renderer === "string" && /Vulkan/i.test(renderer) && !/SwiftShader|llvmpipe/i.test(renderer);
    report("chromium-webgl-gpu", gpu, renderer);
  } finally {
    await browser.close();
  }
}

async function webkitVideo() {
  const browser = await playwright.webkit.launch({ headless: true });
  try {
    const page = await browser.newPage();
    const url = pathToFileURL(video).href;
    await page.goto(pathToFileURL(require("node:path").dirname(video) + "/").href);
    const result = await page.evaluate(async (src) => {
      const element = document.createElement("video");
      element.muted = true;
      element.src = src;
      document.body.append(element);
      const outcome = await new Promise((resolve) => {
        element.onerror = () => resolve({ error: element.error && element.error.message });
        element.ontimeupdate = () => {
          if (element.currentTime > 0.3) resolve({ ok: true });
        };
        element.play().catch((error) => resolve({ error: String(error) }));
        setTimeout(() => resolve({ error: "timed out" }), 15000);
      });
      return { ...outcome, width: element.videoWidth, height: element.videoHeight, time: element.currentTime };
    }, url);
    report("webkit-video-decode", Boolean(result.ok) && result.width > 0, result);
  } finally {
    await browser.close();
  }
}

(async () => {
  for (const check of [webgl, webkitVideo]) {
    try {
      await check();
    } catch (error) {
      report(check.name, false, String(error).split("\n")[0]);
    }
  }
  process.exit(failed ? 1 : 0);
})();
