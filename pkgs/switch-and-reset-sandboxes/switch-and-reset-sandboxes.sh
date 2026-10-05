#!/usr/bin/env bash
set -euo pipefail

reset_sandboxes=false
case "$*" in
	'') ;;
	--reset-sandboxes) reset_sandboxes=true ;;
	*)
		echo "usage: $0 [--reset-sandboxes]" >&2
		exit 2
		;;
esac

# nh uses the checkout configured through programs.nh.flake.
nh os switch

if ! "$reset_sandboxes"; then
	exit 0
fi

mapfile -t units < <(systemctl --user list-units 'agent-sandbox@*' --plain --no-legend --state=active | awk '{print $1}')

systemctl --user stop 'agent-sandbox@*'
docker images -q agent-sandbox | sort -u | xargs -r docker rmi -f
if ((${#units[@]})); then
	systemctl --user start "${units[@]}"
fi
