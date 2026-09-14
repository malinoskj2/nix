#!/usr/bin/env bash
# Give each assigned monitor a random video wallpaper. Run before noctalia
# starts: the mpvpaper plugin reads assignments.json at boot and keeps that
# video until the next launch. Avoids repeating a monitor's previous video and,
# when there are enough videos, showing the same one on two monitors.
# Also forces slideshow mode off, which is what makes the plugin poll mpv.

VIDEO_DIR="$HOME/.wallpapers/video"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/mpvpaper"
STATE_FILE="$STATE_DIR/assignments.json"

mkdir -p "$STATE_DIR"
echo '{"interval":0}' >"$STATE_DIR/slideshow_override.json"

mapfile -t connectors < <(jq -r '.assignments // {} | keys[]' "$STATE_FILE" 2>/dev/null)
mapfile -t videos < <(find "$VIDEO_DIR" -maxdepth 1 -type f -regextype egrep -iregex '.*\.(mp4|webm|mkv|mov|gif)' | shuf)
[ ${#connectors[@]} -gt 0 ] && [ ${#videos[@]} -gt 0 ] || exit 0

declare -A used
new='{}'
for c in "${connectors[@]}"; do
  prev=$(jq -r --arg c "$c" '.assignments[$c]' "$STATE_FILE")
  pick=
  for v in "${videos[@]}"; do
    [ "$v" != "$prev" ] && [ -z "${used[$v]:-}" ] && { pick=$v; break; }
  done
  if [ -z "$pick" ]; then
    for v in "${videos[@]}"; do
      [ "$v" != "$prev" ] && { pick=$v; break; }
    done
  fi
  pick=${pick:-${videos[0]}}
  used[$pick]=1
  new=$(jq --arg c "$c" --arg v "$pick" '.[$c] = $v' <<<"$new")
done

tmp=$(mktemp "$STATE_FILE.XXXXXX")
jq --argjson a "$new" '.assignments = $a' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
