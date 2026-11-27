# shellcheck shell=bash
# Sourced by agent-sandbox.sh, whose variables it reads and sets.
# shellcheck disable=SC2034,SC2154
# Without the broker's egress config the launcher keeps Docker's default bridge and published ports.

egress_config=${AGENT_SANDBOX_EGRESS_CONFIG:-/etc/agent-broker/egress.json}
egress=
egress_args=()
egress_runner_args=()
ingress_dir=
ingress_pids=()

egress_control() {
  local reply
  if ! reply=$(socat -t 10 - "UNIX-CONNECT:$egress_gate" <<<"$1" 2>/dev/null) || [[ -z $reply ]]; then
    echo "agent-sandbox: the egress gate at $egress_gate isn't answering; check systemctl status agent-broker-egress-gate" >&2
    return 1
  fi
  if [[ $(jq -r .ok <<<"$reply") != true ]]; then
    echo "agent-sandbox: the egress gate refused: $(jq -r .error <<<"$reply")" >&2
    return 1
  fi
  printf '%s\n' "$reply"
}

egress_init() {
  local network group gid
  if [[ ! -r $egress_config ]]; then
    return 0
  fi
  egress_gate=$(jq -r .sandbox.gate "$egress_config")
  if [[ -n $steam ]]; then
    echo "agent-sandbox: a Steam sandbox keeps Docker's bridge network, so its traffic bypasses the egress proxy" >&2
    egress_control "$(jq -nc --arg name "$sandbox_instance" \
      '{op: "exception", name: $name, reason: "steam sandbox keeps the bridge network"}')" >/dev/null || true
    return 0
  fi
  network=$(jq -r .sandbox.network "$egress_config")
  group=$(jq -r .sandbox.group "$egress_config")
  if ! gid=$(getent group "$group" | cut -d: -f3) || [[ -z $gid ]]; then
    echo "agent-sandbox: group $group is missing" >&2
    exit 1
  fi
  if ! docker network inspect "$network" >/dev/null 2>&1; then
    docker network create --internal --driver bridge \
      --opt "com.docker.network.bridge.name=$(jq -r .sandbox.bridge "$egress_config")" \
      --label agent-sandbox.egress=1 "$network" >/dev/null 2>&1 ||
      docker network inspect "$network" >/dev/null
  fi
  egress=1
  egress_network=$network
  ingress_dir=$runtime/agent-sandbox-ingress/$sandbox_instance
  mkdir -p "$ingress_dir"
  chmod 700 "$runtime/agent-sandbox-ingress" "$ingress_dir"
  egress_args=(
    --network "$network"
    --group-add "$gid"
    --env-file "$AGENT_SANDBOX_EGRESS_ENV"
    --volume "$ingress_dir:/run/agent-ingress"
  )
  local push
  push=$(jq -r '.sandbox.push // empty' "$egress_config")
  if [[ -n $push && -d $push ]]; then
    egress_args+=(--volume "$push:/run/agent-push:ro")
  fi
  egress_runner_args=(--egress-config "$egress_config" --egress-env "$AGENT_SANDBOX_EGRESS_ENV")
}

# Swaps the --publish entries for host-side forwarders into the sandbox's ingress sockets, as
# published ports don't reach an internal network, and registers the sandbox with the gate,
# which allows it its own preview URLs. Binding here also holds the ports until it starts.
# Connecting by name from the ingress directory keeps the socket path under its 108-byte limit, and
# argv[0] names the forwarder for agent-sandbox-kill.
ingress_forward() {
  local bind=$1 host_port=$2 dir=$3 port=$4
  (cd "$dir" && exec -a "agent-sandbox-ingress $dir" socat \
    "TCP-LISTEN:$host_port,bind=$bind,fork,reuseaddr" "UNIX-CONNECT:$port.sock") >/dev/null 2>&1 &
}

egress_publish() {
  local -a kept=() previews=()
  local spec bind host_port port pid reply subnets
  ingress_stop
  while (($#)); do
    if [[ $1 == --publish ]]; then
      spec=$2
      port=${spec##*:}
      spec=${spec%:*}
      host_port=${spec##*:}
      bind=0.0.0.0
      if [[ $spec == *:* ]]; then
        bind=${spec%:*}
      else
        previews+=("$host_port")
      fi
      ingress_forward "$bind" "$host_port" "$ingress_dir" "$port"
      ingress_pids+=($!)
      shift 2
    else
      kept+=("$1")
      shift
    fi
  done
  sleep 0.2
  for pid in "${ingress_pids[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      ingress_stop
      return 1
    fi
  done
  # The proxy lets the sandbox reach its own network's addresses, as it can directly.
  subnets=$(docker network inspect "$egress_network" --format '{{json .IPAM.Config}}' 2>/dev/null | jq -c '[.[]?.Subnet // empty]' 2>/dev/null) || true
  [[ -n $subnets ]] || subnets='[]'
  reply=$(egress_control "$(jq -nc --arg name "$sandbox_instance" --argjson pid $$ \
    --arg address "$preview_address" --argjson ports "$(printf '%s\n' "${previews[@]}" | jq -sc 'map(tonumber)')" \
    --argjson networks "$subnets" \
    '{op: "register", name: $name, pid: $pid, preview: {address: $address, ports: $ports}, networks: $networks}')") || exit 1
  publish_args=("${kept[@]}" --volume "$(jq -r .dir <<<"$reply"):/run/agent-egress:ro")
}

ingress_stop() {
  if ((${#ingress_pids[@]})); then
    kill "${ingress_pids[@]}" 2>/dev/null || true
    wait "${ingress_pids[@]}" 2>/dev/null || true
  fi
  ingress_pids=()
}

egress_cleanup() {
  ingress_stop
  if [[ -n $egress ]]; then
    egress_control "$(jq -nc --arg name "$sandbox_instance" '{op: "unregister", name: $name}')" >/dev/null || true
  fi
  if [[ -n $ingress_dir ]]; then
    rm -f -- "$ingress_dir"/*.sock
    rmdir -- "$ingress_dir" 2>/dev/null || true
  fi
}
