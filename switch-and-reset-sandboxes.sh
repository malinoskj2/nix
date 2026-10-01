#!/usr/bin/env bash
set -euo pipefail

nh os switch "$(dirname "$(realpath "$0")")"

mapfile -t units < <(systemctl --user list-units 'agent-sandbox@*' --plain --no-legend --state=active | awk '{print $1}')

systemctl --user stop 'agent-sandbox@*'
docker images -q agent-sandbox | sort -u | xargs -r docker rmi -f
if ((${#units[@]})); then
  systemctl --user start "${units[@]}"
fi
