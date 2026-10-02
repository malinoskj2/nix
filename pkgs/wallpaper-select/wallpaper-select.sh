#!/usr/bin/env bash
# The video is loaded straight into the running mpv, and recorded as the monitor's assignment so a
# restarted mpvpaper keeps it. The next session assigns a new one.

readonly video_dir="$HOME/.wallpapers/video"
readonly state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper"
readonly state_file="$state_dir/assignments.json"
readonly j2bar="${J2BAR_BIN:-j2bar}"

usage() {
  cat <<'EOF'
Usage: wallpaper-select [monitor]

Switch a monitor's running video wallpaper to one picked in j2bar's launcher.
The monitor defaults to the focused one.
EOF
}

die() {
  printf 'wallpaper-select: %s\n' "$*" >&2
  exit 1
}

send_to_mpv() {
  local socket="$1"

  socat - "UNIX-CONNECT:$socket" 2>/dev/null
}

query_video_path() {
  local socket="$1"

  printf '{"command":["get_property","path"]}\n' | send_to_mpv "$socket"
}

# The launcher shows what follows the tab as the entry's description.
list_videos() {
  local current="$1"
  local name

  find "$video_dir" -maxdepth 1 -type f -regextype egrep -iregex '.*\.(mp4|webm|mkv|mov|gif)' \
    -printf '%f\n' |
    sort |
    while read -r name; do
      if [[ "$video_dir/$name" == "$current" ]]; then
        printf '%s\tcurrent\n' "$name"
      else
        printf '%s\n' "$name"
      fi
    done
}

assign() {
  local monitor="$1"
  local target="$2"
  local temp_file

  exec 9>"$state_dir/lock"
  flock 9
  if ! jq -e '.assignments | type == "object"' "$state_file" >/dev/null 2>&1; then
    printf '{"assignments":{}}\n' >"$state_file"
  fi
  temp_file="$(mktemp "$state_file.XXXXXX")"
  jq --arg monitor "$monitor" --arg target "$target" '.assignments[$monitor] = $target' \
    "$state_file" >"$temp_file" && mv "$temp_file" "$state_file"
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

monitor="${1:-$(hyprctl -j monitors | jq -r '.[] | select(.focused) | .name')}"
socket="$state_dir/ipc-$monitor.sock"

if ! query_video_path "$socket" | jq -e '.error == "success"' >/dev/null; then
  die "no running video wallpaper on $monitor"
fi
current="$(query_video_path "$socket" | jq -r '.data')"

choice="$(list_videos "$current" | "$j2bar" dmenu -p "Wallpaper ($monitor)")" || true
choice="${choice%%$'\t'*}"
[[ -n "$choice" ]] || exit 0

# Text typed into the launcher comes back as it is when it matches nothing.
target="$video_dir/$choice"
[[ "$choice" != */* && -f "$target" ]] || die "not a video in $video_dir: $choice"
[[ "$target" != "$current" ]] || exit 0

jq -nc --arg target "$target" '{command: ["loadfile", $target, "replace"]}' |
  send_to_mpv "$socket" >/dev/null
assign "$monitor" "$target"
