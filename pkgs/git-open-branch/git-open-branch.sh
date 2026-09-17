#!/usr/bin/env bash

# open website associated with remote

url="$(git remote get-url origin)" || exit 1

case "$url" in
	git@*) url="https://$(printf '%s' "${url#git@}" | sed 's|:|/|')" ;;
	ssh://*) url="https://$(printf '%s' "${url#ssh://}" | sed 's|^[^@]*@||; s|:[0-9]*/|/|')" ;;
esac
url="${url%.git}"

branch="$(git branch --show-current)"
[ -n "$branch" ] && url="$url/tree/$branch"

if [ -n "${BROWSER:-}" ]; then
	"$BROWSER" "$url"
elif command -v open >/dev/null 2>&1; then
	open "$url"
else
	xdg-open "$url"
fi
