base=$1
target=$2

# Claude Code saves /effort to these keys, so they keep the interactive value
# over Nix's.
existing='{}'
if [[ -s $target ]] && jq -e 'type == "object"' "$target" >/dev/null 2>&1; then
  existing=$(<"$target")
fi

tmp=$(mktemp "$target.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq --slurpfile base "$base" \
  '$base[0] * with_entries(select(.key == "effortLevel" or .key == "modelSettings"))' \
  <<<"$existing" >"$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$target"
