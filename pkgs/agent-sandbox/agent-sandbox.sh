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
shared=("$HOME/projects" "$HOME/nix" "$HOME/orca/workspaces" "$HOME/.cache/img2char3d" "$HOME/.local/share/Steam/steamapps/common")
screenshots=/tmp/screenshot
media=/tmp/agent-media
orca_relay_dir=$runtime/agent-sandbox-orca
image_ref="agent-sandbox:${AGENT_SANDBOX_TAG#hash-}"
clipboard_dir=$(mktemp --directory "$runtime/agent-sandbox-clipboard.XXXXXX")

# Keep bind mounts in order: writable child mounts override read-only parents.
mounts=()

mount_readonly() {
  local src=$1 dst=${2:-$1}
  if [[ $dst == "$HOME"/* ]]; then
    local placeholder=$sandbox_home${dst#"$HOME"}
    if [[ -d $src ]]; then
      mkdir -p "$placeholder"
    elif [[ -f $src ]]; then
      mkdir -p "$(dirname "$placeholder")"
      touch "$placeholder"
    else
      return 0
    fi
  elif [[ ! -e $src ]]; then
    return 0
  fi
  mounts+=(--volume "$src:$dst:ro")
}

copy_if_newer() {
  local src=$1 dst=$2
  if [[ -f $src && (! -f $dst || $src -nt $dst) ]]; then
    cp "$src" "$dst"
  fi
}

seed_if_empty() {
  local src=$1 dst=$2
  if [[ -f $src && ! -s $dst ]]; then
    cp "$src" "$dst"
    chmod u+w "$dst"
  fi
}

configure_claude() {
  local name
  for name in CLAUDE.md settings.json skills hooks agents commands output-styles plugins rules; do
    mount_readonly "$HOME/.claude/$name"
  done

  for name in tasks tasks-archive projects; do
    mkdir -p "$HOME/.claude/$name" "$sandbox_home/.claude/$name"
    mounts+=(--volume "$HOME/.claude/$name:$HOME/.claude/$name")
  done

  if [[ -d $HOME/.claude/plugins/data ]]; then
    mkdir -p "$data/plugin-data"
    mounts+=(--volume "$data/plugin-data:$HOME/.claude/plugins/data")
  fi
}

configure_codex() {
  # Every sandbox can run Codex, including Orca's SSH hosts. Authentication
  # follows the newer copy; writable config is seeded once, including empty
  # placeholders left by older launches.
  copy_if_newer "$HOME/.codex/auth.json" "$sandbox_home/.codex/auth.json"
  seed_if_empty "$HOME/.codex/config.toml" "$sandbox_home/.codex/config.toml"

  local name
  for name in AGENTS.md rules skills plugins; do
    mount_readonly "$HOME/.codex/$name"
  done
}

configure_zcode() {
  # Preserve logins/provider changes from either environment. Settings are
  # seeded once so later host edits cannot overwrite sandbox tool permissions.
  local name
  for name in v2/provider_config.json v2/credentials.json; do
    copy_if_newer "$HOME/.zcode/$name" "$sandbox_home/.zcode/$name"
  done
  seed_if_empty "$HOME/.zcode/cli/setting.json" "$sandbox_home/.zcode/cli/setting.json"
}

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
mkdir -p "$orca_relay_dir"
chmod 700 "$orca_relay_dir"

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

configure_claude
configure_codex
configure_zcode

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
args+=(--volume "$orca_relay_dir:$orca_relay_dir")
args+=(--volume "$clipboard_dir:/run/host-clipboard:ro")
args+=(--volume "$ssh_dir/host_ed25519:/run/agent-sandbox-ssh/host_ed25519:ro")
args+=(--volume "$ssh_dir/authorized_keys:/run/agent-sandbox-ssh/authorized_keys:ro")

if [[ -d $HOME/.config/git ]]; then
  mount_readonly "$HOME/.config/git"
fi
# Orca's CLI reads its runtime metadata and connects to the desktop's Unix
# socket from this directory. Keep Orca's mutable workspace state host-owned.
if [[ -d $HOME/.config/orca ]]; then
  mount_readonly "$HOME/.config/orca"
fi

# The display draws text, icons and Hyprland's compositing the way the desktop does: its fonts and
# their rendering settings, its desktop entries and icon themes, and its Hyprland look.lua.
if [[ -f /etc/fonts/fonts.conf ]]; then
  args+=(--volume /etc/fonts:/etc/fonts:ro --env FONTCONFIG_FILE=/etc/fonts/fonts.conf)
fi
for dir in "$HOME/.config/fontconfig" "$HOME/.local/share/fonts"; do
  if [[ -d $dir ]]; then
    mount_readonly "$dir"
  fi
done
if [[ -f $HOME/.config/hypr/look.lua ]]; then
  mount_readonly "$HOME/.config/hypr" /run/host-hypr
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

args+=("${mounts[@]}")

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
