#!/usr/bin/env bash

uid=$(id -u)
# The host's nix-daemon trusts root, and the container would share the daemon socket.
if [[ $uid == 0 ]]; then
  echo "agent-sandbox: refusing to run as root" >&2
  exit 2
fi
gid=$(id -g)
user=$(id -un)
group=$(id -gn)
runtime=/run/user/$uid

# --display brings up the headless displays at startup; without it, agents start them with
# sandbox-display. --steam (or AGENT_SANDBOX_STEAM=1) loosens seccomp and /proc for Steam and
# Proton. Without an agent flag, the arguments are the container's command, Claude by default.
display=
steam=
if [[ ${AGENT_SANDBOX_STEAM:-} == 1 ]]; then
  steam=1
fi
agent=
while [[ $# -gt 0 ]]; do
  case $1 in
    --display)
      display=1
      shift
      ;;
    --steam)
      steam=1
      shift
      ;;
    --claude | --codex | --antigravity | --opencode)
      agent=${1#--}
      shift
      break
      ;;
    *) break ;;
  esac
done

data=${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox
sandbox_home=$data/home
model_root=$HOME/.local/share/models
if [[ -s $HOME/.config/local-models/root ]]; then
  model_root=$(<"$HOME/.config/local-models/root")
fi
model_stores=()
if [[ -s $HOME/.config/local-models/stores ]]; then
  mapfile -t model_stores <"$HOME/.config/local-models/stores"
fi
steam_common=$HOME/.local/share/Steam/steamapps/common
shared=(
  "$HOME/projects"
  "$HOME/projects-archive"
  "$HOME/Downloads"
  "$HOME/orca/workspaces"
  "$HOME/.orca/bots"
  "$HOME/.cache/img2char3d"
  "$steam_common"
  "$HOME/.local/share/unreal-engine"
)
# Only Tohru merges to main and switches hosts, and her home holds her instructions and memory.
nix_repo=$HOME/nix
tohru_home=$HOME/.orca/bots/tohru
media=/tmp/agent-media
media_share=/mnt/media3/agent-sandbox
asset_archive=/mnt/media3/agent
orca_relay_dir=$runtime/agent-sandbox-orca
# Never under the shared hook directory above: a sandbox reaches only its own relay.
orca_relays=$runtime/agent-sandbox-orca-relay
orca_data=${ORCA_USER_DATA_PATH:-$HOME/.config/orca}
if [[ $orca_data != /* || $orca_data == *:* ]]; then
  echo 'agent-sandbox: invalid ORCA_USER_DATA_PATH' >&2
  exit 2
fi
codex_socket_dir=$runtime/agent-sandbox-codex
gpu_lease_dir=$runtime/gpu-scheduler
gallery_registry=$HOME/.local/state/media-gallery
# On disk: tmpfs is charged to the slice as shmem, which no OOM kill frees.
tmp_root=$data/tmp
container_tmp=$tmp_root/$$
ssh_dir=$data/ssh
image_ref="agent-sandbox:${AGENT_SANDBOX_TAG#hash-}"

workdir=$HOME/projects
for dir in "${shared[@]}" "$nix_repo"; do
  if [[ $PWD == "$dir" || $PWD == "$dir"/* ]]; then
    workdir=$PWD
  fi
done

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

# A path with no symlink in it, so neither Docker nor the container can be pointed elsewhere.
plain_dir() {
  [[ -d $1 && $(realpath -e -- "$1") == "$1" ]]
}

# Whether a path is, or is inside, a directory sandboxes may only read.
protected_path() {
  local path dir
  path=$(realpath -m -- "$1")
  for dir in "$nix_repo" "$tohru_home"; do
    dir=$(realpath -m -- "$dir")
    if [[ $path == "$dir" || $path == "$dir"/* ]]; then
      return 0
    fi
  done
  return 1
}

# ~/nix is read-only. A sandbox still commits, branches, rebases and fetches in its own worktree,
# whose admin directory, objects, reflogs and remote-tracking refs live in ~/nix/.git. The main
# checkout, .git/config, hooks, info, HEAD, packed-refs and every top-level branch, main among
# them, stay read-only. Git replaces a file by renaming its lock over it, and a host-side rename
# detaches a file bind in every other mount namespace, so each writable part is a directory.
nix_repo_mounts() {
  local git=$nix_repo/.git dir prefix
  args+=(--volume "$nix_repo:$nix_repo:ro")
  plain_dir "$git/refs/heads" || return 0
  # Branches under a prefix that only packed-refs holds have no directory to mount yet.
  while read -r prefix; do
    if [[ $prefix =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && ! -e $git/refs/heads/$prefix ]]; then
      mkdir "$git/refs/heads/$prefix"
    fi
  done < <(sed -nE 's|^[0-9a-f]{40} refs/heads/([^/]+)/.*|\1|p' "$git/packed-refs" 2>/dev/null | sort -u)
  for dir in "$git/objects" "$git/logs" "$git/worktrees" "$git/refs/remotes" "$git/refs/tags" "$git"/refs/heads/*/; do
    dir=${dir%/}
    if plain_dir "$dir"; then
      args+=(--volume "$dir:$dir")
    fi
  done
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
  # Writable so /effort can save; Home Manager re-merges it on each switch.
  seed_if_empty "$HOME/.claude/settings.json" "$sandbox_home/.claude/settings.json"

  local name
  for name in CLAUDE.md skills hooks agents commands output-styles plugins rules; do
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
  for name in AGENTS.md pstack-models.md rules skills plugins; do
    mount_readonly "$HOME/.codex/$name"
  done
}

configure_antigravity() {
  # Without a Secret Service in the container, agy keeps its login in this file. A host whose agy
  # also falls back to it shares its login, as with Codex.
  copy_if_newer "$HOME/.gemini/antigravity-cli/antigravity-oauth-token" \
    "$sandbox_home/.gemini/antigravity-cli/antigravity-oauth-token"
  # agy saves trust, model and /config choices here; Home Manager re-merges Nix's keys on each switch.
  seed_if_empty "$HOME/.gemini/antigravity-cli/settings.json" "$sandbox_home/.gemini/antigravity-cli/settings.json"

  mount_readonly "$HOME/.gemini/GEMINI.md"
  mount_readonly "$HOME/.gemini/config/skills"
  mount_readonly "$AGENT_SANDBOX_INSTRUCTIONS" "$HOME/.gemini/config/AGENTS.md"
}

configure_opencode() {
  # The image's /etc/opencode config outranks these, swapping in the sandbox's MCP servers and a
  # placeholder Venice key that the egress proxy replaces.
  local name
  for name in opencode.json AGENTS.md skills; do
    mount_readonly "$HOME/.config/opencode/$name"
  done
}

# Proton and the Steam Linux Runtimes a sandbox client installs before launching a game, which
# the sandbox keeps its own copies of so that it never rewrites the host's.
is_steam_tool() {
  case $1 in
    Proton* | SteamLinuxRuntime* | "Steamworks Shared") return 0 ;;
    *) return 1 ;;
  esac
}

steam_running_in_sandbox() {
  local pid
  for pid in $(pgrep -x steam); do
    if grep -q /agent-sandbox.slice/ "/proc/$pid/cgroup" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

configure_steam() {
  # Steam rewrites manifests while it runs, and every sandbox shares one home.
  local root
  root=$(readlink -f "$HOME/.steam/root" 2>/dev/null) || return 0
  if [[ ! -d $root/steamapps ]] || steam_running_in_sandbox; then
    return 0
  fi
  local dst=$sandbox_home/.local/share/Steam
  mkdir -p "$dst/steamapps"

  # steamapps/common is the host's, so a sandbox client left to update in the
  # background would rewrite the host's games and Proton builds behind the
  # host's manifests. Copies update only when the sandbox launches them.
  local manifest copy installdir
  for manifest in "$root"/steamapps/appmanifest_*.acf; do
    installdir=$(sed -nE 's/^\s*"installdir"\s+"(.*)"\s*$/\1/p' "$manifest" 2>/dev/null)
    copy=$dst/steamapps/${manifest##*/}
    if is_steam_tool "$installdir"; then
      # A manifest copied from the host before the tools were split would claim the empty copy is installed.
      if [[ -z $(ls -A "$data/steam-tools/$installdir" 2>/dev/null) ]]; then
        rm -f "$copy"
      fi
      continue
    fi
    if [[ -f $manifest && (! -f $copy || $manifest -nt $copy) ]]; then
      sed -E 's/^(\s*"AutoUpdateBehavior"\s+)"[0-9]+"/\1"1"/' "$manifest" >"$copy"
    fi
  done
}

# Keys for serving SSH sessions from the container. Only the host key and the
# client's public key go into the container.
configure_ssh() {
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  local key
  for key in host client; do
    if [[ ! -f $ssh_dir/${key}_ed25519 ]]; then
      ssh-keygen -q -t ed25519 -N '' -C "agent-sandbox-$key" -f "$ssh_dir/${key}_ed25519"
    fi
  done
  cp "$ssh_dir/client_ed25519.pub" "$ssh_dir/authorized_keys"
  printf 'agent-sandbox %s\n' "$(<"$ssh_dir/host_ed25519.pub")" >"$ssh_dir/known_hosts"
}

write_accounts() {
  printf 'root:x:0:0::/root:/bin/sh\n%s:x:%s:%s::%s:/bin/bash\n' "$user" "$uid" "$gid" "$HOME" >"$data/passwd"
  printf 'root:x:0:\n%s:x:%s:%s\n' "$group" "$gid" "$user" >"$data/group"
}

# Host ports every container publishes, including created ones that don't listen yet.
reserved_ports=" "
read_reserved_ports() {
  local ids
  mapfile -t ids < <(docker ps -aq)
  reserved_ports=" "
  if [[ ${#ids[@]} -gt 0 ]]; then
    reserved_ports+=$(docker container inspect --format \
      '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}' "${ids[@]}" |
      tr '\n' ' ')
  fi
}

free_port() {
  local port=$1
  while [[ $reserved_ports == *" $port "* ]] || (: <"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
    port=$((port + 1))
  done
  echo "$port"
}

cleanup() {
  trap - EXIT
  # The desktop owns the launcher, not the container's PID namespace. Stop the
  # container explicitly on cancellation or Orca exit, even if stdin is held open.
  if [[ -n ${cid:-} ]]; then
    docker rm --force "$cid" >/dev/null 2>&1 || true
  fi
  if declare -F egress_cleanup >/dev/null; then
    egress_cleanup
  fi
  # The runner removes the sandboxes and stacks this one started before it exits.
  if [[ -n ${runner_pid:-} ]]; then
    kill "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
  fi
  if [[ -n ${runner_dir:-} ]]; then
    rm -f -- "$runner_dir/runner.sock" "$runner_dir/runner.log"
    rmdir -- "$runner_dir" 2>/dev/null || true
  fi
  if [[ -n ${orca_relay_pid:-} ]]; then
    kill "$orca_relay_pid" 2>/dev/null || true
    wait "$orca_relay_pid" 2>/dev/null || true
  fi
  if [[ -n ${orca_relay:-} ]]; then
    rm -rf -- "$orca_relay"
  fi
  remove_tmp "$container_tmp"
}

remove_tmp() {
  chmod -R u+w -- "$1" 2>/dev/null || true
  rm -rf -- "$1"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

mkdir -p "$sandbox_home/.claude" "$sandbox_home/.codex" "$sandbox_home/.config/git" \
  "$sandbox_home/.gemini/antigravity-cli" "$sandbox_home/.gemini/config"
for dir in "${shared[@]}" "$nix_repo"; do
  mkdir -p "$dir" "$sandbox_home${dir#"$HOME"}"
done
mkdir -p "$media"
mkdir -p "$model_root" 2>/dev/null || true
mount_readonly "$model_root"
for store in "${model_stores[@]}"; do
  if [[ -n $store ]]; then mount_readonly "$store"; fi
done
mkdir -p "$orca_relay_dir" "$orca_relays"
chmod 700 "$orca_relay_dir" "$orca_relays"
for dir in "$orca_relays"/relay.*/; do
  dir=${dir%/}
  pid=${dir##*/relay.}
  if [[ -d $dir && (! $pid =~ ^[0-9]+$ || ! -d /proc/$pid) ]]; then
    rm -rf -- "$dir"
  fi
done
orca_relay=$orca_relays/relay.$$
rm -rf -- "$orca_relay"
mkdir -m 700 "$orca_relay" "$orca_relay/data"
mkdir -p "$gpu_lease_dir"
chmod 700 "$gpu_lease_dir"
mkdir -p "$gallery_registry"
mkdir -p "$codex_socket_dir"
chmod 700 "$codex_socket_dir"
# A launcher killed before its cleanup leaves its directory behind.
mkdir -p "$tmp_root"
for dir in "$tmp_root"/*/; do
  dir=${dir%/}
  if [[ ! ${dir##*/} =~ ^[0-9]+$ ]] || ! kill -0 "${dir##*/}" 2>/dev/null; then
    remove_tmp "$dir"
  fi
done
mkdir -p "$container_tmp"
configure_ssh
write_accounts
# The one Codex app-server every sandbox's codex-image shares; a host without the unit has none.
systemctl --user start --no-block agent-sandbox-codex-server.service 2>/dev/null || true

if ! docker image inspect "$image_ref" >/dev/null 2>&1; then
  "$AGENT_SANDBOX_IMAGE" | docker load >/dev/null
fi

# Codex reads it directly; the Claude and Antigravity skill folders link into it.
mount_readonly "$HOME/.agents/skills"
configure_claude
configure_codex
configure_antigravity
configure_opencode
configure_steam

sandbox_instance=${AGENT_SANDBOX_NAME:-agent-sandbox-$(basename "$workdir")-$$}

# Preview ports are published on every interface, and their URLs use the LAN
# address, so the links also open on other devices.
preview_address=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
preview_address=${preview_address:-127.0.0.1}

egress_args=()
egress_runner_args=()
# shellcheck source=/dev/null
source "$AGENT_SANDBOX_EGRESS_LIB"
egress_init

# The runner is this sandbox's only way to the host engine: disposable sibling sandboxes and
# review Compose stacks, which it labels with this instance and removes when the sandbox goes.
docker_socket=/run/docker.sock
if [[ ${DOCKER_HOST:-} == unix://* ]]; then
  docker_socket=${DOCKER_HOST#unix://}
fi
mkdir -p "$runtime/agent-sandbox-runner"
chmod 700 "$runtime/agent-sandbox-runner"
runner_dir=$(mktemp -d "$runtime/agent-sandbox-runner/XXXXXXXX")
runner_roots=()
for dir in "$HOME/projects" "$HOME/projects-archive" "$HOME/orca/workspaces" "$HOME/.orca/bots"; do
  runner_roots+=(--root "$dir")
done
runner_roots+=(--deny "$tohru_home")
"$AGENT_SANDBOX_RUNNER" --owner "$sandbox_instance" --socket "$runner_dir/runner.sock" \
  --state-dir "$data/runner/$(sha256sum <<<"$sandbox_instance" | cut -c1-16)" \
  --image "$image_ref" "${runner_roots[@]}" --passwd "$data/passwd" --group "$data/group" \
  --ports-lock "$runtime/agent-sandbox-ports.lock" --gpu-lease-dir "$gpu_lease_dir" \
  --seccomp-profile "$AGENT_SANDBOX_SECCOMP" \
  --preview-address "$preview_address" "${egress_runner_args[@]}" \
  --docker-socket "$docker_socket" >"$runner_dir/runner.log" 2>&1 &
runner_pid=$!

# Sandboxes reach Orca only through this relay, which holds the desktop's token
# on the host and forwards the runtime methods agents need. The container sees
# a profile of its own at Orca's path, naming the relay's socket and no token.
# It names this sandbox to Orca from the launch's own ORCA_* variables in its environment.
orca_relay_args=(--agent "$agent")
if [[ $workdir == "$HOME/.orca/bots"/* ]]; then
  orca_relay_args+=(--bot)
fi
"$AGENT_SANDBOX_ORCA_RELAY" --host-data "$orca_data" --data "$orca_relay/data" --container-data "$orca_data" \
  --preview-file "$orca_relay/preview-origins" "${orca_relay_args[@]}" >"$orca_relay/relay.log" 2>&1 &
orca_relay_pid=$!
for _ in {1..100}; do
  [[ -S $orca_relay/data/relay.sock ]] && break
  if ! kill -0 "$orca_relay_pid" 2>/dev/null; then
    echo "agent-sandbox: Orca relay failed" >&2
    cat "$orca_relay/relay.log" >&2
    exit 1
  fi
  sleep 0.02
done

# Docker can't create a mount point inside the read-only profile, so make each one there first.
orca_mount_point() {
  local path=$1 rel
  [[ $path == "$orca_data"/* ]] || return 0
  rel=${path#"$orca_data"/}
  if [[ -d $path ]]; then
    mkdir -p "$orca_relay/data/$rel"
  else
    mkdir -p "$orca_relay/data/${rel%/*}"
    touch "$orca_relay/data/$rel"
  fi
}
args=(
  --rm
  --init
  --name "$sandbox_instance"
  --hostname agent-sandbox
  --user "$uid:$gid"
  --cap-drop ALL
  --security-opt no-new-privileges
  # Steam's crash reporter would upload sandbox client dumps to Valve.
  --add-host crash.steampowered.com:0.0.0.0
  --add-host crash.steampowered.com:::
  --pids-limit 8192
  # Memory limits come from the slice, which reclaims before it kills.
  --cgroup-parent agent-sandbox.slice
  # The container's cgroup namespace hides the shared parent limit and usage.
  --mount "type=bind,src=/sys/fs/cgroup/agent.slice/agent-sandbox.slice,dst=/run/agent-sandbox-cgroup,readonly"
  # The parent also bounds the host's Nix builds alongside every sandbox.
  --mount "type=bind,src=/sys/fs/cgroup/agent.slice,dst=/run/agent-cgroup,readonly"
  # No Docker cpuset: the slice's AllowedCPUs changes while a game runs, and a
  # container's own cpuset would pin it to whatever was set at launch.
  # Under host-wide OOM, kill sandbox processes before the desktop's.
  --oom-score-adj 500
  --shm-size 2g
  --device nvidia.com/gpu=all
  --volume "$container_tmp:/tmp"
  --tmpfs "$runtime:mode=0700,uid=$uid,gid=$gid"
  --mount "type=bind,src=$gpu_lease_dir,dst=$gpu_lease_dir"
  --mount "type=bind,src=$gallery_registry,dst=$gallery_registry"
  --volume /nix/store:/nix/store:ro
  --volume /nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket
  --volume "$data/passwd:/etc/passwd:ro"
  --volume "$data/group:/etc/group:ro"
  --volume /etc/localtime:/etc/localtime:ro
  --volume "$sandbox_home:$HOME"
  --workdir "$workdir"
  --env HOME
  --env MODEL_ROOT="$model_root"
  --env HF_HUB_CACHE="$model_root/huggingface"
  --env IMG2VIDEO_MODELS="$model_root/by-name/img2video"
  --env SAM="$model_root/by-name/sam2.1"
  --env CUDA_CACHE_MAXSIZE=4294967296
  --env USER="$user"
  --env TERM
  --env COLORTERM
  --env AGENT_SANDBOX_INSTANCE="$sandbox_instance"
  --env AGENT_SANDBOX_IMAGE_TAG="${image_ref#agent-sandbox:}"
  --env AGENT_SANDBOX_RUNNER_SOCKET=/run/agent-sandbox-runner/runner.sock
  --volume "$runner_dir:/run/agent-sandbox-runner:ro"
  --env AGENT_SANDBOX_RENDERERS
  --env AGENT_SANDBOX_DISPLAY="$display"
  --env AGENT_SANDBOX_STEAM="$steam"
  --env XDG_RUNTIME_DIR="$runtime"
  --env DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus"
  --env SWAYSOCK="$runtime/sway.sock"
)
if [[ -n $steam ]]; then
  # Steam's FHS wrapper and Proton's pressure-vessel run bubblewrap, which needs
  # unprivileged user namespaces and an unmasked /proc to mount a fresh one.
  args+=(--security-opt seccomp=unconfined --security-opt systempaths=unconfined)
else
  args+=(--security-opt "seccomp=$AGENT_SANDBOX_SECCOMP")
fi

# Forward only the specific Orca fields agents and hook scripts use, not the
# host environment. With a hook bridge socket, PATH switches to the Orca curl
# shim inside the container so hook URLs reach the desktop through the relay.
for name in \
  ORCA_PANE_KEY ORCA_TAB_ID ORCA_WORKTREE_ID ORCA_TERMINAL_HANDLE \
  ORCA_AGENT_LAUNCH_TOKEN ORCA_AGENT_HOOK_ENDPOINT \
  ORCA_AGENT_HOOK_PORT ORCA_AGENT_HOOK_TOKEN ORCA_AGENT_HOOK_ENV \
  ORCA_AGENT_HOOK_VERSION ORCA_AGENT_HOOK_TRANSPORT \
  ORCA_STRUCTURED_SESSION ORCA_AGENT_SESSION_ID ORCA_AGENT_SESSION_SPAWN_TOKEN \
  ORCA_USER_DATA_PATH ORCA_CLI_COMMAND ORCA_ENVIRONMENT \
  ORCA_CHAT_SCRATCH_DIR; do
  if [[ -v $name ]]; then
    args+=(--env "$name=${!name}")
  fi
done
# The Chat host has already selected Claude's account and scrubbed inherited
# credentials. Preserve that selection only for Claude, not other harnesses.
if [[ $agent == claude ]]; then
  for name in \
    CLAUDE_CODE_ENTRYPOINT CLAUDE_AGENT_SDK_VERSION \
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS \
    CLAUDE_CODE_OAUTH_TOKEN AWS_BEARER_TOKEN_BEDROCK; do
    if [[ -v $name ]]; then
      args+=(--env "$name=${!name}")
    fi
  done
fi
# Each launch's hook bridge has its own directory; a sandbox sees only its own.
if [[ -n ${ORCA_AGENT_HOOK_SOCKET:-} ]]; then
  hook_dir=${ORCA_AGENT_HOOK_SOCKET%/hook.sock}
  if [[ $hook_dir != "$orca_relay_dir"/session.* || ${hook_dir#"$orca_relay_dir"/} == */* ||
    $ORCA_AGENT_HOOK_SOCKET != "$hook_dir/hook.sock" ]] || ! plain_dir "$hook_dir"; then
    echo "agent-sandbox: refusing Orca hook socket outside $orca_relay_dir" >&2
    exit 2
  fi
  args+=(--env "PATH=$AGENT_SANDBOX_ORCA_PATH" --env "ORCA_AGENT_HOOK_SOCKET=$ORCA_AGENT_HOOK_SOCKET")
  args+=(--volume "$hook_dir:$hook_dir")
fi

for dir in "${shared[@]}"; do
  args+=(--volume "$dir:$dir")
done
for dir in "$steam_common"/*/; do
  dir=${dir%/}
  if is_steam_tool "${dir##*/}"; then
    mkdir -p "$data/steam-tools/${dir##*/}"
    args+=(--volume "$data/steam-tools/${dir##*/}:$dir")
  fi
done
nix_repo_mounts
if [[ -L $tohru_home ]] || { [[ -e $tohru_home ]] && ! plain_dir "$tohru_home"; }; then
  echo "agent-sandbox: refusing to start: $tohru_home is not a plain directory" >&2
  exit 2
elif [[ -d $tohru_home ]]; then
  args+=(--volume "$tohru_home:$tohru_home:ro")
fi
args+=(
  --volume "$media:$media"
  --volume "$codex_socket_dir:/run/agent-sandbox-codex:ro"
  --volume "$ssh_dir/host_ed25519:/run/agent-sandbox-ssh/host_ed25519:ro"
  --volume "$ssh_dir/authorized_keys:/run/agent-sandbox-ssh/authorized_keys:ro"
)
# The media host's NFS share is automounted, and binding a directory inside it
# keeps it mounted while the sandbox runs. Skip it when the host is unreachable.
if timeout 15 test -d "$media_share"; then
  args+=(--volume "$media_share:$media_share")
fi
if timeout 15 test -d /mnt/media3 &&
  findmnt -rn -T /mnt/media3 -t nfs,nfs4 >/dev/null &&
  timeout 15 mkdir -p "$asset_archive"; then
  args+=(--mount "type=bind,src=$asset_archive,dst=$asset_archive")
fi
# The NVIDIA CDI spec mounts only the 64-bit driver; Steam's 32-bit client needs the other half.
if [[ -e /run/opengl-driver-32 ]]; then
  args+=(--volume /run/opengl-driver-32:/run/opengl-driver-32:ro)
fi

mount_readonly "$HOME/.config/git"
# Home Manager writes the image tag it installs here, so a session can tell it runs a stale image.
mount_readonly "$HOME/.config/agent-sandbox" /run/agent-sandbox-host
mount_readonly "$HOME/.config/last30days/.env"
mount_readonly "$orca_relay/data" "$orca_data"
# Chat hands agents the files people attach or paste by their path in Orca's profile.
for dir in agent-session-attachments native-chat-pastes; do
  if [[ -d $orca_data/$dir ]]; then
    orca_mount_point "$orca_data/$dir"
    args+=(--volume "$orca_data/$dir:$orca_data/$dir:ro")
  fi
done

# Chat pins an account directory before spawning the provider. Preserve that
# identity and its writable transcripts/config.
account_variable=
case $agent in
  codex) account_variable=CODEX_HOME ;;
  claude) account_variable=CLAUDE_CONFIG_DIR ;;
esac
if [[ -n $account_variable && -n ${!account_variable:-} ]]; then
  account_home=${!account_variable}
  if [[ $account_home != /* || ! -d $account_home || $account_home == *:* ]] || protected_path "$account_home"; then
    echo "agent-sandbox: invalid $account_variable directory" >&2
    exit 2
  fi
  orca_mount_point "$account_home"
  args+=(--env "$account_variable=$account_home" --volume "$account_home:$account_home")
  if [[ $PWD == "$account_home" || $PWD == "$account_home"/* ]]; then
    args+=(--workdir "$PWD")
  fi
fi

# Inline Chat artifacts have a dedicated per-session directory under Orca state.
if [[ -n ${ORCA_CHAT_SCRATCH_DIR:-} ]]; then
  if [[ $ORCA_CHAT_SCRATCH_DIR != /* || ! -d $ORCA_CHAT_SCRATCH_DIR || $ORCA_CHAT_SCRATCH_DIR == *:* ]] ||
    protected_path "$ORCA_CHAT_SCRATCH_DIR"; then
    echo 'agent-sandbox: invalid ORCA_CHAT_SCRATCH_DIR directory' >&2
    exit 2
  fi
  orca_mount_point "$ORCA_CHAT_SCRATCH_DIR"
  args+=(--volume "$ORCA_CHAT_SCRATCH_DIR:$ORCA_CHAT_SCRATCH_DIR")
fi

# The display draws text, icons and Hyprland's compositing the way the desktop does: its fonts and
# their rendering settings, its desktop entries and icon themes, and its Hyprland look.lua.
if [[ -f /etc/fonts/fonts.conf ]]; then
  args+=(--volume /etc/fonts:/etc/fonts:ro --env FONTCONFIG_FILE=/etc/fonts/fonts.conf)
fi
mount_readonly "$HOME/.config/fontconfig"
mount_readonly "$HOME/.local/share/fonts"
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

args+=("${mounts[@]}" "${egress_args[@]}")

args+=(--interactive)
if [[ -t 0 && -t 1 ]]; then
  args+=(--tty)
fi

case $agent in
  claude) set -- claude --dangerously-skip-permissions "$@" ;;
  codex) set -- codex --dangerously-bypass-approvals-and-sandbox "$@" ;;
  antigravity) set -- agy --dangerously-skip-permissions "$@" ;;
  opencode) set -- opencode "$@" ;;
esac

# The identity's own preview ports, kept across restarts. A sandbox stopping for a restart
# can still hold them for a moment; another live one of the same identity keeps them.
preview_base=
if [[ -n ${AGENT_SANDBOX_PREVIEW_PORTS_TOOL:-} ]]; then
  preview_identity=${AGENT_SANDBOX_IDENTITY:-${AGENT_SANDBOX_NAME:-$workdir}}
  preview_base=$("$AGENT_SANDBOX_PREVIEW_PORTS_TOOL" "$preview_identity") || preview_base=
fi
preview_ports_free() {
  local port
  for ((port = preview_base; port < preview_base + 5; port++)); do
    if [[ $reserved_ports == *" $port "* ]] || (: <"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      return 1
    fi
  done
}
if [[ -n $preview_base ]]; then
  for _ in {1..12}; do
    preview_ports_free && break
    sleep 0.25
  done
fi

# Serialize port selection with container creation across concurrent
# launches. A created container binds its ports only when it starts, so the
# probe also skips every port an existing container publishes.
exec 9>"$runtime/agent-sandbox-ports.lock"
cid=
for _ in {1..5}; do
  flock 9
  read_reserved_ports
  vnc_port=$(free_port 5900)
  hyprland_vnc_port=$(free_port $((vnc_port + 1)))
  novnc_port=$(free_port 6080)
  novnc_url="http://127.0.0.1:$novnc_port/vnc.html?autoconnect=1&resize=scale"
  publish_args=(
    --publish "127.0.0.1:$vnc_port:5900"
    --publish "127.0.0.1:$hyprland_vnc_port:5901"
    --publish "127.0.0.1:$novnc_port:6080"
    --env AGENT_SANDBOX_VNC_URL="$novnc_url"
    --env 'AGENT_PREVIEW_PORTS=8080 8081 8082 8083 8084'
  )
  preview_host_port=18080
  stable_preview=
  if [[ -n $preview_base ]]; then
    if preview_ports_free; then
      stable_preview=1
      preview_host_port=$preview_base
    else
      echo "agent-sandbox: preview ports $preview_base-$((preview_base + 4)) are in use, so this launch takes others" >&2
    fi
    # A failed attempt may have lost them, so a retry searches.
    preview_base=
  fi
  preview_origins=()
  for preview_port in {8080..8084}; do
    [[ -n $stable_preview ]] || preview_host_port=$(free_port "$preview_host_port")
    while [[ -z $stable_preview ]] && [[ $preview_host_port == "$vnc_port" || $preview_host_port == "$hyprland_vnc_port" || $preview_host_port == "$novnc_port" ]]; do
      preview_host_port=$(free_port $((preview_host_port + 1)))
    done
    publish_args+=(
      --publish "$preview_host_port:$preview_port"
      --env "AGENT_PREVIEW_URL_$preview_port=http://$preview_address:$preview_host_port"
    )
    preview_origins+=("http://$preview_address:$preview_host_port")
    preview_host_port=$((preview_host_port + 1))
  done
  if [[ -n $egress ]] && ! egress_publish "${publish_args[@]}"; then
    continue
  fi
  if cid=$(docker create "${args[@]}" "${publish_args[@]}" "$image_ref" "$@"); then
    break
  fi
  cid=
done
flock -u 9
if [[ -z $cid ]]; then
  echo "agent-sandbox: could not create the sandbox container" >&2
  exit 1
fi
# The relay lets Orca's browser open only this sandbox's own preview addresses.
printf '%s\n' "${preview_origins[@]}" >"$orca_relay/preview-origins"

echo "agent-sandbox: VNC on 127.0.0.1:$vnc_port, nested Hyprland on 127.0.0.1:$hyprland_vnc_port" >&2
echo "agent-sandbox: VNC in the browser at $novnc_url" >&2
if [[ -z $display ]]; then
  echo "agent-sandbox: displays start when an agent runs sandbox-display up; launch with --display to start them now" >&2
fi

# A named sandbox is the long-lived SSH host that agent-sandbox@.service runs;
# inhibiting idle for its lifetime would keep the machine awake indefinitely.
if [[ -n ${AGENT_SANDBOX_NAME:-} ]]; then
  docker start --attach --interactive "$cid"
else
  systemd-inhibit --what=idle --who=agent-sandbox --why="agent sandbox running" \
    docker start --attach --interactive "$cid"
fi
