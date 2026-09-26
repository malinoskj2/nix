#!/usr/bin/env bash

# ssh runs this as a ProxyCommand: stdout and stdin carry the SSH protocol, so
# nothing may write to stdout before sshd takes over.

alias=${1:?usage: agent-sandbox-ssh <host alias>}
if [[ ! $alias =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "agent-sandbox-ssh: invalid alias: $alias" >&2
  exit 1
fi

unit=agent-sandbox@$alias.service
container=agent-sandbox-$alias
config=/run/user/$(id -u)/sshd_config

systemctl --user start "$unit"

# The entrypoint writes the sshd config once the container is up; before that,
# an sshd session would start without the sandbox's environment.
for _ in $(seq 900); do
  if docker exec "$container" test -s "$config" 2>/dev/null; then
    exec docker exec --interactive "$container" "$AGENT_SANDBOX_SSHD" -i -e -f "$config"
  fi
  if ! systemctl --user --quiet is-active "$unit"; then
    echo "agent-sandbox-ssh: $unit stopped; see journalctl --user -u $unit" >&2
    exit 1
  fi
  sleep 0.2
done

echo "agent-sandbox-ssh: timed out waiting for $container" >&2
exit 1
