#!/usr/bin/env bash

uid=$(id -u)
gid=$(id -g)
data=${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox
sandbox_home=$data/home
socket_dir=$XDG_RUNTIME_DIR/agent-sandbox-codex
image_ref="agent-sandbox:${AGENT_SANDBOX_TAG#hash-}"
name=agent-sandbox-codex-server

# The sandbox launcher writes these and starts this server.
if [[ ! -f $data/passwd || ! -f $data/group ]]; then
  echo "agent-sandbox-codex-server: start a sandbox first" >&2
  exit 1
fi

# Sandboxes bind this directory at startup, so it is never replaced, only emptied.
mkdir -p "$socket_dir" "$sandbox_home/.codex"
find "$socket_dir" -mindepth 1 -delete

if ! docker image inspect "$image_ref" >/dev/null 2>&1; then
  "$AGENT_SANDBOX_IMAGE" | docker load >/dev/null
fi
docker rm --force "$name" >/dev/null 2>&1 || true

# Codex puts the socket in /tmp/codex-daemon-$UID and leaves only a symlink at
# the listen path, so that directory is the one sandboxes see.
exec docker run \
  --rm \
  --init \
  --name "$name" \
  --hostname agent-sandbox \
  --user "$uid:$gid" \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 1024 \
  --cgroup-parent agent-sandbox.slice \
  --cpuset-cpus "8-15,24-31" \
  --tmpfs "/tmp:mode=1777,size=256m" \
  --volume "$socket_dir:/tmp/codex-daemon-$uid" \
  --volume /nix/store:/nix/store:ro \
  --volume "$data/passwd:/etc/passwd:ro" \
  --volume "$data/group:/etc/group:ro" \
  --volume /etc/localtime:/etc/localtime:ro \
  --volume "$sandbox_home:$HOME" \
  --workdir "$HOME" \
  --env HOME \
  --env USER="$(id -un)" \
  --entrypoint "$AGENT_SANDBOX_CODEX_SERVER_ENTRYPOINT" \
  "$image_ref"
