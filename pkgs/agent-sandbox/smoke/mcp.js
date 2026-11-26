"use strict";

// Usage: node mcp.js <playwright-mcp command>. Drives the MCP over stdio as an agent would: open a
// page, then read its WebGL renderer, which must be ANGLE on Vulkan.
const { spawn } = require("node:child_process");

const server = spawn(process.argv[2], ["--headless", "--output-dir", process.env.SMOKE_MCP_OUTPUT ?? "/tmp"], {
  stdio: ["pipe", "pipe", "inherit"],
});
let buffer = "";
const pending = new Map();
server.stdout.on("data", (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (!line.trim()) continue;
    const message = JSON.parse(line);
    pending.get(message.id)?.(message);
  }
});

let nextId = 1;
function request(method, params) {
  const id = nextId++;
  server.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${method} timed out`)), 60000);
    pending.set(id, (message) => {
      clearTimeout(timer);
      message.error ? reject(new Error(JSON.stringify(message.error))) : resolve(message.result);
    });
  });
}

function text(result) {
  return (result.content ?? []).map((part) => part.text ?? "").join("\n");
}

(async () => {
  let ok = false;
  let detail;
  try {
    await request("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "sandbox-smoke", version: "1" },
    });
    server.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
    const page = "data:text/html,<title>sandbox-smoke</title><canvas id=c></canvas>";
    const navigated = await request("tools/call", { name: "browser_navigate", arguments: { url: page } });
    if (navigated.isError) throw new Error(text(navigated));
    const evaluated = await request("tools/call", {
      name: "browser_evaluate",
      arguments: {
        function: `() => {
          const gl = document.getElementById("c").getContext("webgl2") ?? document.getElementById("c").getContext("webgl");
          const info = gl && gl.getExtension("WEBGL_debug_renderer_info");
          return info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : String(gl && gl.getParameter(gl.RENDERER));
        }`,
      },
    });
    detail = text(evaluated);
    ok = !evaluated.isError && /Vulkan/i.test(detail) && !/SwiftShader|llvmpipe/i.test(detail);
  } catch (error) {
    detail = String(error).split("\n")[0];
  }
  console.log(JSON.stringify({ check: "playwright-mcp-navigate-webgl", ok, detail: detail?.slice(0, 400) }));
  server.kill();
  process.exit(ok ? 0 : 1);
})();
