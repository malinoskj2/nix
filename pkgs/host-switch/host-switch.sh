#!/usr/bin/env bash

repo=/home/jesse/nix
dir="$repo/.tmp/host-switch"
timeout=${HOST_SWITCH_TIMEOUT:-3600}

if [[ $# -gt 0 ]]; then
  echo 'Usage: host-switch' >&2
  exit 2
fi
if [[ ! -w "$dir" ]]; then
  echo "host-switch: $dir is missing; the host-switch service is not deployed" >&2
  exit 1
fi

commit=$(git -C "$repo" rev-parse refs/heads/main)
printf '%s\n' "$commit" >"$dir/request"
echo "host-switch: requested $commit"

deadline=$((SECONDS + timeout))
while ((SECONDS < deadline)); do
  if read -r got state code _ <"$dir/status" 2>/dev/null && [[ "$got" == "$commit" || "$got" == invalid ]]; then
    case "$state" in
      done)
        echo "host-switch: switched to $commit"
        exit 0
        ;;
      failed)
        echo "host-switch: switch failed (exit $code); log: $dir/$commit.log" >&2
        tail -n 40 "$dir/$commit.log" >&2
        exit 1
        ;;
      refused)
        echo "host-switch: refused; only the head of main is switched (exit $code)" >&2
        exit 1
        ;;
    esac
  fi
  sleep 2
done
echo "host-switch: no result after ${timeout}s; check $dir/status" >&2
exit 1
