#!/usr/bin/env bash

repo=/home/jesse/nix
dir="$repo/.tmp/host-switch"
timeout=${HOST_SWITCH_TIMEOUT:-3600}

# --expect asks for that exact commit: the service refuses it, without
# activating anything, unless it is still the head of main when it starts.
expect=''
case $# in
  0) ;;
  2)
    if [[ $1 != --expect || ! $2 =~ ^[0-9a-f]{40}$ ]]; then
      echo 'Usage: host-switch [--expect <40-hex commit>]' >&2
      exit 2
    fi
    expect=$2
    ;;
  *)
    echo 'Usage: host-switch [--expect <40-hex commit>]' >&2
    exit 2
    ;;
esac
if [[ ! -w "$dir" ]]; then
  echo "host-switch: $dir is missing; the host-switch service is not deployed" >&2
  exit 1
fi

commit=${expect:-$(git -c core.hooksPath=/dev/null -c core.fsmonitor=false -C "$repo" rev-parse refs/heads/main)}
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
        case $code in
          2) echo 'host-switch: refused: the request was not a commit' >&2 ;;
          3) echo "host-switch: refused: $commit is not the head of main" >&2 ;;
          4) echo "host-switch: refused: $repo's Git config or hooks would run programs" >&2 ;;
          5) echo 'host-switch: refused: cannot read main from GitHub' >&2 ;;
          6) echo "host-switch: refused: $commit is not main on GitHub; push it first" >&2 ;;
          *) echo "host-switch: refused (exit $code)" >&2 ;;
        esac
        [[ -f $dir/$commit.log ]] && tail -n 20 "$dir/$commit.log" >&2
        exit 1
        ;;
    esac
  fi
  sleep 2
done
echo "host-switch: no result after ${timeout}s; check $dir/status" >&2
exit 1
