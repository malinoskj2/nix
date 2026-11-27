# shellcheck shell=bash
if browser-gpu-probe; then
  set -- --config "$SANDBOX_PLAYWRIGHT_MCP_GPU_CONFIG" "$@"
else
  echo "playwright-mcp: no Vulkan GPU found, so Chromium falls back to SwiftShader: expect slow WebGL frames, ReadPixels stalls and delayed input" >&2
  set -- --config "$SANDBOX_PLAYWRIGHT_MCP_CPU_CONFIG" "$@"
fi
if [[ -n ${HTTPS_PROXY:-} ]]; then
  set -- --proxy-server "$HTTPS_PROXY" --proxy-bypass "${NO_PROXY:-}" "$@"
fi
exec "$SANDBOX_PLAYWRIGHT_MCP" "$@"
