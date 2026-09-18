#!/usr/bin/env bash

uid=$(id -u)
gid=$(id -g)
user=$(id -un)
group=$(id -gn)
runtime=/run/user/$uid

data=${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox
sandbox_home=$data/home
shared=("$HOME/projects" "$HOME/nix")

mkdir -p "$sandbox_home/.claude" "$sandbox_home/.config/git"
for dir in "${shared[@]}"; do
  mkdir -p "$dir" "$sandbox_home${dir#"$HOME"}"
done

printf 'root:x:0:0::/root:/bin/sh\n%s:x:%s:%s::%s:/bin/bash\n' "$user" "$uid" "$gid" "$HOME" >"$data/passwd"
printf 'root:x:0:\n%s:x:%s:%s\n' "$group" "$gid" "$user" >"$data/group"

if ! docker image inspect "$AGENT_SANDBOX_REF" >/dev/null 2>&1; then
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

if [[ -d $HOME/.claude/plugins/data ]]; then
  mkdir -p "$data/plugin-data"
  args+=(--volume "$data/plugin-data:$HOME/.claude/plugins/data")
fi

if [[ -t 0 && -t 1 ]]; then
  args+=(--interactive --tty)
else
  args+=(--interactive)
fi

echo "agent-sandbox: VNC on 127.0.0.1:$vnc_port" >&2
exec docker run "${args[@]}" "$AGENT_SANDBOX_REF" "$@"
