#!/usr/bin/env bash
# Restore existing containers after boot. Never create containers or data.
set -euo pipefail

disk=/mnt/media3
data=$disk/skin-trader/postgres
apps=(skin-trader-api skin-trader-collector skin-trader-compute)

fail() {
  echo "skin-trader startup: $*" >&2
  exit 1
}

mountpoint -q "$disk" || fail "$disk is not mounted"
[ "$(stat -c %d "$disk")" != "$(stat -c %d /)" ] || fail "$disk is on the OS filesystem"
[ ! -L "$data" ] && [ -s "$data/PG_VERSION" ] && [ -s "$data/global/pg_control" ] || fail 'existing PostgreSQL cluster is missing or symlinked'
[ "$(cat "$data/PG_VERSION")" = 17 ] || fail 'existing PostgreSQL cluster is not version 17'

# Validate every existing container before starting anything. Docker must not
# substitute a volume or a directory on the OS disk after a missing data mount.
for container in skin-trader-postgres "${apps[@]}"; do
  project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container")
  [ "$project" = skin-trader ] || fail "$container is not owned by the skin-trader Compose project"
  if [ "$container" = skin-trader-postgres ]; then
    target=/var/lib/postgresql/data
    expected="bind:$data:true"
  else
    target=/postgres-data
    expected="bind:$data:false"
  fi
  mount=$(docker inspect --format "{{range .Mounts}}{{if eq .Destination \"$target\"}}{{.Type}}:{{.Source}}:{{.RW}}{{end}}{{end}}" "$container")
  [ "$mount" = "$expected" ] || fail "$container has an unexpected data mount: $mount"
done

docker start skin-trader-postgres >/dev/null
# A HDD crash recovery can take several minutes. Repeated service attempts
# leave PostgreSQL running so that a slow recovery keeps making progress.
for ((attempt = 0; attempt < 120; attempt++)); do
  state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' skin-trader-postgres)
  if [ "$state" = 'running healthy' ]; then
    docker start "${apps[@]}" >/dev/null
    echo 'skin-trader startup: PostgreSQL ready; API and workers started'
    exit 0
  fi
  sleep 5
done
fail 'PostgreSQL did not become ready within 10 minutes; leaving recovery running'
