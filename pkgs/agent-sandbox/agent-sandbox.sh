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
elif [[ ${1:-} == --opencode ]]; then
  agent=opencode
  shift
elif [[ ${1:-} == --zcode ]]; then
  agent=zcode
  shift
fi

data=${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox
sandbox_home=$data/home
shared=("$HOME/projects" "$HOME/nix" "$HOME/orca/workspaces" "$HOME/.cache/img2char3d")
screenshots=/tmp/screenshot
media=/tmp/agent-media
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

mkdir -p "$sandbox_home/.claude" "$sandbox_home/.codex" "$sandbox_home/.zcode/cli" "$sandbox_home/.zcode/v2" "$sandbox_home/.config/git"
for dir in "${shared[@]}"; do
  mkdir -p "$dir" "$sandbox_home${dir#"$HOME"}"
done
mkdir -p "$screenshots" "$media"

# Keys for serving SSH sessions from the container (agent-sandbox-ssh). Only the
# host key and the client's public key go into the container.
ssh_dir=$data/ssh
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
for key in host client; do
  if [[ ! -f $ssh_dir/${key}_ed25519 ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "agent-sandbox-$key" -f "$ssh_dir/${key}_ed25519"
  fi
done
cp "$ssh_dir/client_ed25519.pub" "$ssh_dir/authorized_keys"
printf 'agent-sandbox %s\n' "$(<"$ssh_dir/host_ed25519.pub")" >"$ssh_dir/known_hosts"

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

free_port() {
  local port=$1
  while (: <"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
    port=$((port + 1))
  done
  echo "$port"
}

vnc_port=$(free_port 5900)
hyprland_vnc_port=$(free_port $((vnc_port + 1)))

args=(
  --rm
  --init
  --name "${AGENT_SANDBOX_NAME:-agent-sandbox-$(basename "$workdir")-$$}"
  --hostname agent-sandbox
  --user "$uid:$gid"
  --cap-drop ALL
  --security-opt no-new-privileges
  --pids-limit 8192
  # Memory limits come from the slice, which reclaims before it kills.
  --cgroup-parent agent-sandbox.slice
  # Only the non-V-Cache CCD1, including its SMT siblings. The desktop can
  # still use all cores; GameMode pins registered games to CCD0 separately.
  --cpuset-cpus "8-15,24-31"
  --shm-size 2g
  --device nvidia.com/gpu=all
  --publish "127.0.0.1:$vnc_port:5900"
  --publish "127.0.0.1:$hyprland_vnc_port:5901"
  # tmpfs is charged to the slice as shmem, and killing processes doesn't free
  # it. Uncapped, an agent filling it starves every sandbox of the slice limit.
  --tmpfs "/tmp:exec,mode=1777,size=4g"
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
args+=(--volume "$media:$media")
args+=(--volume "$clipboard_dir:/run/host-clipboard:ro")
args+=(--volume "$ssh_dir/host_ed25519:/run/agent-sandbox-ssh/host_ed25519:ro")
args+=(--volume "$ssh_dir/authorized_keys:/run/agent-sandbox-ssh/authorized_keys:ro")

if [[ -d $HOME/.config/git ]]; then
  args+=(--volume "$HOME/.config/git:$HOME/.config/git:ro")
fi

# The display draws text, icons and Hyprland's compositing the way the desktop does: its fonts and
# their rendering settings, its desktop entries and icon themes, and its Hyprland look.lua.
if [[ -f /etc/fonts/fonts.conf ]]; then
  args+=(--volume /etc/fonts:/etc/fonts:ro --env FONTCONFIG_FILE=/etc/fonts/fonts.conf)
fi
for dir in "$HOME/.config/fontconfig" "$HOME/.local/share/fonts"; do
  if [[ -d $dir ]]; then
    mkdir -p "$sandbox_home${dir#"$HOME"}"
    args+=(--volume "$dir:$dir:ro")
  fi
done
if [[ -f $HOME/.config/hypr/look.lua ]]; then
  args+=(--volume "$HOME/.config/hypr:/run/host-hypr:ro")
fi
# The profiles these name aren't mounted, so their store paths stand in for them.
data_dirs=()
IFS=: read -ra host_data_dirs <<<"${XDG_DATA_DIRS:-}"
for dir in "${host_data_dirs[@]}"; do
  if dir=$(realpath -e "$dir" 2>/dev/null) && [[ $dir == /nix/store/* ]]; then
    data_dirs+=("$dir")
  fi
done
if [[ ${#data_dirs[@]} -gt 0 ]]; then
  joined=$(printf '%s:' "${data_dirs[@]}")
  args+=(--env "XDG_DATA_DIRS=${joined%:}")
fi

for name in CLAUDE.md settings.json skills hooks agents commands output-styles plugins rules; do
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

for name in tasks tasks-archive projects; do
  mkdir -p "$HOME/.claude/$name" "$sandbox_home/.claude/$name"
  args+=(--volume "$HOME/.claude/$name:$HOME/.claude/$name")
done

if [[ -d $HOME/.claude/plugins/data ]]; then
  mkdir -p "$data/plugin-data"
  args+=(--volume "$data/plugin-data:$HOME/.claude/plugins/data")
fi

# Every sandbox can run Codex, including the SSH hosts Orca launches it in.
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

for name in AGENTS.md rules skills plugins; do
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

# Seed ZCode's provider and credential state from the host, newer copy wins, so
# a login or provider change in either environment is not lost on the next launch.
for name in v2/provider_config.json v2/credentials.json; do
  src=$HOME/.zcode/$name
  dst=$sandbox_home/.zcode/$name
  if [[ -f $src && (! -f $dst || $src -nt $dst) ]]; then
    cp "$src" "$dst"
  fi
done

# The CLI settings file is seeded once so ZCode can persist theme and tool
# permissions without later host edits clobbering them.
if [[ -f $HOME/.zcode/cli/setting.json && ! -s $sandbox_home/.zcode/cli/setting.json ]]; then
  cp "$HOME/.zcode/cli/setting.json" "$sandbox_home/.zcode/cli/setting.json"
  chmod u+w "$sandbox_home/.zcode/cli/setting.json"
fi

if [[ -t 0 && -t 1 ]]; then
  args+=(--interactive --tty)
else
  args+=(--interactive)
fi

echo "agent-sandbox: VNC on 127.0.0.1:$vnc_port, nested Hyprland on 127.0.0.1:$hyprland_vnc_port" >&2
if [[ $agent == codex ]]; then
  set -- codex --dangerously-bypass-approvals-and-sandbox "$@"
elif [[ $agent == opencode ]]; then
  set -- opencode "$@"
elif [[ $agent == zcode ]]; then
  set -- zcode "$@"
fi
# A named sandbox is the long-lived SSH host that agent-sandbox@.service runs;
# inhibiting idle for its lifetime would keep the machine awake indefinitely.
if [[ -n ${AGENT_SANDBOX_NAME:-} ]]; then
  docker run "${args[@]}" "$image_ref" "$@"
else
  systemd-inhibit --what=idle --who=agent-sandbox --why="agent sandbox running" \
    docker run "${args[@]}" "$image_ref" "$@"
fi
