#!/usr/bin/env bash
# Open the origin remote's web page for the current branch.
#
# SSH remotes are rewritten to HTTPS on the same host and path. A detached HEAD opens the
# repository root. The page opens with $BROWSER when set, otherwise open or xdg-open.

url="$(git remote get-url origin)" || exit 1

case "$url" in
  git@*) url="https://$(printf '%s' "${url#git@}" | sed 's|:|/|')" ;;
  ssh://*) url="https://$(printf '%s' "${url#ssh://}" | sed 's|^[^@]*@||; s|:[0-9]*/|/|')" ;;
esac
url="${url%.git}"

branch="$(git branch --show-current)"
url+="${branch:+/tree/$branch}"

if [[ -n "${BROWSER:-}" ]]; then
  "$BROWSER" "$url"
elif command -v open >/dev/null 2>&1; then
  open "$url"
else
  xdg-open "$url"
fi
