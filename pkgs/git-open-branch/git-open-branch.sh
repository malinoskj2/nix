#!/usr/bin/env bash

url="$(
  git remote get-url origin |
    sed -E '
      s|^git@([^:]+):|https://\1/|
      s|^ssh://([^@/]*@)?([^:/]+)(:[0-9]*)?/|https://\2/|
      s|^https://[^@/]*@|https://|
      s|\.git$||
    '
)" || exit 1

branch="$(git branch --show-current)"
case "$url" in
  https://bitbucket.org/*) url+="${branch:+/src/$branch}" ;;
  *) url+="${branch:+/tree/$branch}" ;;
esac

if [[ -n "${BROWSER:-}" ]]; then
  "$BROWSER" "$url"
elif command -v open >/dev/null 2>&1; then
  open "$url"
else
  xdg-open "$url"
fi
