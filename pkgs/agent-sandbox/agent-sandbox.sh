#!/usr/bin/env bash

uid=$(id -u)
gid=$(id -g)
user=$(id -un)
group=$(id -gn)
runtime=/run/user/$uid

agent=claude
if [[ ${1:-} == --codex ]]; then
  agent=codex
  shift
fi

data=${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox
sandbox_home=$data/home
shared=("$HOME/projects" "$HOME/nix" "$HOME/.cache/img2char3d")
screenshots=/tmp/screenshot
image_ref="agent-sandbox:${AGENT_SANDBOX_TAG#hash-}"
clipboard_dir=$(mktemp --directory "$runtime/agent-sandbox-clipboard.XXXXXX")

cleanup() {
  trap - EXIT
  if [[ -n ${clipboard_watcher_pid:-} ]]; then
    kill "$clipboard_watcher_pid" 2>/dev/null || true
    wait "$clipboard_watcher_pid" 2>/dev/null || true
  fi
  rm -f -- "$clipboard_dir/image" "$clipboard_dir/.change" "$clipboard_dir/watcher.log"
  rmdir -- "$clipboard_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

# Mirror the host image clipboard through an isolated bind mount. A host-side
# watcher is required because the sandbox has its own headless Wayland session.
CLIPBOARD_STATE=data agent-sandbox-clipboard-sync "$clipboard_dir" \
  < <(wl-paste --type image 2>/dev/null)
wl-paste --type image --watch agent-sandbox-clipboard-sync "$clipboard_dir" \
  >/dev/null 2>"$clipboard_dir/watcher.log" &
clipboard_watcher_pid=$!

mkdir -p "$sandbox_home/.claude" "$sandbox_home/.codex" "$sandbox_home/.config/git"
for dir in "${shared[@]}"; do
  mkdir -p "$dir" "$sandbox_home${dir#"$HOME"}"
done
mkdir -p "$screenshots"

printf 'root:x:0:0::/root:/bin/sh\n%s:x:%s:%s::%s:/bin/bash\n' "$user" "$uid" "$gid" "$HOME" >"$data/passwd"
printf 'root:x:0:\n%s:x:%s:%s\n' "$group" "$gid" "$user" >"$data/group"

if ! docker image inspect "$image_ref" >/dev/null 2>&1; then
  "$AGENT_SANDBOX_IMAGE" | docker load >/dev/null
fi

workdir=$HOME/projects
for dir in "${shared[@]}"; do
  if [[ $PWD == "$dir" || $PWD == "$dir"/* ]]; then
    workdir=$PWD
  fi
done

vnc_port=5900
while (: <"/dev/tcp/127.0.0.1/$vnc_port") 2>/dev/null; do
  vnc_port=$((vnc_port + 1))
done

args=(
  --rm
  --init
  --name "agent-sandbox-$(basename "$workdir")-$$"
  --hostname agent-sandbox
  --user "$uid:$gid"
  --cap-drop ALL
  --security-opt no-new-privileges
  --pids-limit 8192
  # Memory limits come from the slice, which reclaims before it kills.
  --cgroup-parent agent-sandbox.slice
  # All of CCD1 plus half of CCD0, leaving cores 0-3 and their SMT siblings to
  # the desktop alone.
  --cpuset-cpus "4-15,20-31"
  --shm-size 2g
  --device nvidia.com/gpu=all
  --publish "127.0.0.1:$vnc_port:5900"
  --tmpfs "/tmp:exec,mode=1777"
  --tmpfs "$runtime:mode=0700,uid=$uid,gid=$gid"
  --volume /nix/store:/nix/store:ro
  --volume /nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket
  --volume "$data/passwd:/etc/passwd:ro"
  --volume "$data/group:/etc/group:ro"
  --volume /etc/localtime:/etc/localtime:ro
  --volume "$sandbox_home:$HOME"
  --workdir "$workdir"
  --env HOME
  --env USER="$user"
  --env TERM
  --env COLORTERM
  --env AGENT_SANDBOX_RENDERERS
  --env XDG_RUNTIME_DIR="$runtime"
  --env DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus"
  --env SWAYSOCK="$runtime/sway.sock"
)

for dir in "${shared[@]}"; do
  args+=(--volume "$dir:$dir")
done
args+=(--volume "$screenshots:$screenshots:ro")
args+=(--volume "$clipboard_dir:/run/host-clipboard:ro")

if [[ -d $HOME/.config/git ]]; then
  args+=(--volume "$HOME/.config/git:$HOME/.config/git:ro")
fi

for name in CLAUDE.md settings.json skills hooks agents commands output-styles plugins; do
  src=$HOME/.claude/$name
  if [[ -d $src ]]; then
    mkdir -p "$sandbox_home/.claude/$name"
  elif [[ -f $src ]]; then
    touch "$sandbox_home/.claude/$name"
  else
    continue
  fi
  args+=(--volume "$src:$HOME/.claude/$name:ro")
done

for name in tasks tasks-archive; do
  mkdir -p "$HOME/.claude/$name" "$sandbox_home/.claude/$name"
  args+=(--volume "$HOME/.claude/$name:$HOME/.claude/$name")
done

if [[ -d $HOME/.claude/plugins/data ]]; then
  mkdir -p "$data/plugin-data"
  args+=(--volume "$data/plugin-data:$HOME/.claude/plugins/data")
fi

if [[ $agent == codex ]]; then
  # Keep mutable Codex state isolated, but seed authentication from the host. The
  # newer copy wins so a token refreshed in either environment is not replaced by
  # an older one on the next launch.
  if [[ -f $HOME/.codex/auth.json && (! -f $sandbox_home/.codex/auth.json || $HOME/.codex/auth.json -nt $sandbox_home/.codex/auth.json) ]]; then
    cp "$HOME/.codex/auth.json" "$sandbox_home/.codex/auth.json"
  fi

  # Seed a writable config once so Codex can persist project trust and settings.
  # Older launches left an empty mount placeholder, which also needs seeding.
  if [[ -f $HOME/.codex/config.toml && ! -s $sandbox_home/.codex/config.toml ]]; then
    cp "$HOME/.codex/config.toml" "$sandbox_home/.codex/config.toml"
    chmod u+w "$sandbox_home/.codex/config.toml"
  fi

  for name in rules skills plugins; do
    src=$HOME/.codex/$name
    if [[ -d $src ]]; then
      mkdir -p "$sandbox_home/.codex/$name"
    elif [[ -f $src ]]; then
      touch "$sandbox_home/.codex/$name"
    else
      continue
    fi
    args+=(--volume "$src:$HOME/.codex/$name:ro")
  done
fi

if [[ -t 0 && -t 1 ]]; then
  args+=(--interactive --tty)
else
  args+=(--interactive)
fi

echo "agent-sandbox: VNC on 127.0.0.1:$vnc_port" >&2
if [[ $agent == codex ]]; then
  set -- codex --dangerously-bypass-approvals-and-sandbox "$@"
fi
systemd-inhibit --what=idle --who=agent-sandbox --why="agent sandbox running" \
  docker run "${args[@]}" "$image_ref" "$@"
