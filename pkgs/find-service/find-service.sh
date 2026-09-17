#!/usr/bin/env bash
# Print each host on the home LAN with the given service's port open.
# Usage: find-service <plex|qbittorrent>

readonly network=192.168.1.0/24

usage() {
  cat <<'EOF'
Usage: find-service <plex|qbittorrent>

Print each host on the home LAN with the given service's port open.
EOF
}

case "${1:-}" in
  plex) port=32400 ;;
  qbittorrent) port=8080 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

nmap --open -p "$port" "$network" | awk '/scan report/ { print $5 }'
