#!/usr/bin/env bash

# Checks a sandbox the way a reviewer would use it. --full adds the CPU torch wheel, a
# multi-hundred-megabyte download the first time; --no-gpu skips the browser and display checks.
full='' gpu=1
for arg in "$@"; do
  case $arg in
    --full) full=1 ;;
    --no-gpu) gpu='' ;;
    *)
      echo 'usage: sandbox-smoke [--full] [--no-gpu]' >&2
      exit 2
      ;;
  esac
done

work=$(mktemp -d /tmp/sandbox-smoke.XXXXXX)
log=$work/log
failures=0
cleanup() {
  if [[ -n ${pg_started:-} ]]; then pg_ctl -D "$work/pg" -m immediate stop >/dev/null 2>&1 || true; fi
  if [[ -n ${redis_pid:-} ]]; then kill "$redis_pid" 2>/dev/null || true; fi
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf -- "$work"
}
trap cleanup EXIT

pass() { printf 'ok    %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  if [[ -s $log ]]; then sed 's/^/      /' "$log" | tail -n 15; fi
  failures=$((failures + 1))
}
check() {
  local name=$1
  shift
  if "$@" >"$log" 2>&1; then pass "$name"; else fail "$name"; fi
}

echo "image ${AGENT_SANDBOX_IMAGE_TAG:-unknown}"
if [[ -r /run/agent-sandbox-host/image-tag ]]; then
  current=$(</run/agent-sandbox-host/image-tag)
  if [[ $current == "${AGENT_SANDBOX_IMAGE_TAG:-}" ]]; then
    pass "image is the host's current one"
  else
    : >"$log"
    fail "image is stale: the host now installs $current; restart this session at a safe point"
  fi
fi

for tool in flock setsid lua lua5.4 rust-lints initdb pg_ctl postgres psql redis-server redis-cli \
  docker docker-compose sandbox-runner uv nix grim sandbox-display gpu-run; do
  check "command $tool" command -v "$tool"
done
check 'docker compose plugin' docker compose version
check 'lua is 5.4' sh -c 'lua -v | grep -q "Lua 5.4"'
check 'python tomli_w' python3 -c 'import tomli_w, tomllib; assert tomllib.loads(tomli_w.dumps({"a": 1})) == {"a": 1}'
for name in NODE_PATH GST_PLUGIN_SYSTEM_PATH_1_0 PLAYWRIGHT_BROWSERS_PATH NIX_PATH NIX_LD_LIBRARY_PATH; do
  check "env $name" test -n "${!name:-}"
done
check "require('playwright')" node -e 'require("playwright"); require("sandbox-playwright")'

postgres_check() {
  initdb -D "$work/pg" -A trust -U smoke --no-sync &&
    pg_ctl -D "$work/pg" -o "-k $work -c listen_addresses=''" -l "$work/pg.log" -w start &&
    pg_started=1 &&
    [[ $(psql -h "$work" -U smoke -d postgres -tAc 'select 40 + 2') == 42 ]]
}
check 'postgres initdb, pg_ctl, psql' postgres_check

redis_check() {
  redis-server --port 0 --unixsocket "$work/redis.sock" --save '' --appendonly no >"$work/redis.log" 2>&1 &
  redis_pid=$!
  for _ in {1..50}; do
    [[ -S $work/redis.sock ]] && break
    sleep 0.1
  done
  [[ $(redis-cli -s "$work/redis.sock" ping) == PONG ]]
}
check 'redis-server and redis-cli' redis_check

check "nix run 'nixpkgs#hello'" sh -c "nix run 'nixpkgs#hello' -- --greeting=smoke | grep -qx smoke"
check "nix shell 'nixpkgs#cowsay' 'nixpkgs#hello'" sh -c "nix shell 'nixpkgs#cowsay' 'nixpkgs#hello' -c sh -c 'hello | cowsay' | grep -q Hello"
check 'nix-shell -p through NIX_PATH' sh -c "nix-shell -p hello --run hello | grep -q Hello"

wheels() {
  local packages=(numpy pillow opencv-python-headless)
  uv venv --quiet "$work/venv" &&
    uv pip install --quiet --python "$work/venv/bin/python" "${packages[@]}" &&
    "$work/venv/bin/python" -c 'import numpy, PIL.Image, cv2; assert numpy.ones(3).sum() == 3; cv2.cvtColor(numpy.zeros((2, 2, 3), "uint8"), cv2.COLOR_BGR2GRAY)'
}
check 'uv venv wheels: numpy, pillow, opencv-python-headless' wheels
if [[ -n $full ]]; then
  torch_check() {
    uv pip install --quiet --python "$work/venv/bin/python" --index-url https://download.pytorch.org/whl/cpu torch &&
      CUDA_VISIBLE_DEVICES='' "$work/venv/bin/python" -c 'import torch; assert torch.ones(2, 2).sum().item() == 4'
  }
  check 'uv venv wheel: torch (CPU)' torch_check
fi

if [[ -S ${AGENT_SANDBOX_RUNNER_SOCKET:-/run/agent-sandbox-runner/runner.sock} ]]; then
  check 'sandbox-runner reaches the host runner' sandbox-runner ls
else
  : >"$log"
  echo "skip  sandbox-runner: no host runner socket in this sandbox"
fi

if [[ -n $gpu ]]; then
  ffmpeg -loglevel error -f lavfi -i testsrc=size=320x240:rate=30 -t 3 -c:v libx264 -pix_fmt yuv420p "$work/clip.mp4"
  browsers() {
    node "$SANDBOX_SMOKE_BROWSERS" "$work/clip.mp4"
  }
  mcp() {
    SMOKE_MCP_OUTPUT=$work node "$SANDBOX_SMOKE_MCP" "$SANDBOX_PLAYWRIGHT_MCP"
  }
  display() {
    sandbox-display up | tee "$work/display-status" &&
      grep -q '^wayvnc: up' "$work/display-status" &&
      grim "$work/screen.png" &&
      [[ $(magick identify -format '%wx%h' "$work/screen.png") == 1280x800 ]] &&
      grep -qvx pixman "$XDG_RUNTIME_DIR/renderer"
  }
  gpu_checks() {
    check 'browsers: Chromium WebGL on ANGLE Vulkan, WebKit decodes a local video' browsers
    sed 's/^/      /' "$log"
    check 'Playwright MCP opens a page and renders WebGL on ANGLE Vulkan' mcp
    sed 's/^/      /' "$log"
    check 'sandbox-display up with wayvnc, grim captures 1280x800 on the GPU renderer' display
  }
  if [[ -n ${GPU_LEASE_ID:-} ]]; then
    gpu_checks
  else
    export -f check pass fail gpu_checks browsers mcp display
    export log work failures
    # The checks print their own results; the count comes back through the exit status.
    # shellcheck disable=SC2016 # expanded by the inner shell
    gpu-run --vram 2GiB --name 'sandbox-smoke browsers and display' -- bash -c 'gpu_checks; exit $failures' || failures=$((failures + $?))
  fi
fi

if [[ $failures -gt 0 ]]; then
  echo "sandbox-smoke: $failures check(s) failed"
  exit 1
fi
echo 'sandbox-smoke: all checks passed'
