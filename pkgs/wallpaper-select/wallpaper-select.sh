#!/usr/bin/env bash
# Switch a monitor's running Noctalia video wallpaper to one picked in the Noctalia launcher.
# Usage: wallpaper-select [monitor]
#
# The monitor defaults to the focused one. The video is loaded straight into mpv over the plugin's
# IPC socket, so the plugin never learns about it and a Noctalia restart reverts to its assignment.

readonly video_dir="$HOME/.wallpapers/video"
readonly mpvpaper_dir="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/mpvpaper"

usage() {
  cat <<'EOF'
Usage: wallpaper-select [monitor]

Switch a monitor's running Noctalia video wallpaper to one picked in the Noctalia launcher.
The monitor defaults to the focused one.
EOF
}

die() {
  printf 'wallpaper-select: %s\n' "$*" >&2
  exit 1
}

# Sends the JSON commands on stdin to the mpv behind the socket and prints its replies.
send_to_mpv() {
  local socket="$1"

  socat - "UNIX-CONNECT:$socket" 2>/dev/null
}

# Prints mpv's reply to a request for the path of the file it is playing.
query_video_path() {
  local socket="$1"

  printf '{"command":["get_property","path"]}\n' | send_to_mpv "$socket"
}

# Prints the video file names, marking the one mpv is playing.
list_videos() {
  local current="$1"
  local name

  find "$video_dir" -maxdepth 1 -type f -regextype egrep -iregex '.*\.(mp4|webm|mkv|mov|gif)' \
    -printf '%f\n' |
    sort |
    while read -r name; do
      if [[ "$video_dir/$name" == "$current" ]]; then
        printf '%s (current)\n' "$name"
      else
        printf '%s\n' "$name"
      fi
    done
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

monitor="${1:-$(hyprctl -j monitors | jq -r '.[] | select(.focused) | .name')}"
socket="$mpvpaper_dir/ipc-$monitor.sock"

if ! query_video_path "$socket" | jq -e '.error == "success"' >/dev/null; then
  die "no running video wallpaper on $monitor"
fi
current="$(query_video_path "$socket" | jq -r '.data')"

choice="$(list_videos "$current" | noctalia dmenu -p "Wallpaper ($monitor)")" || true
choice="${choice% (current)}"
[[ -n "$choice" ]] || exit 0

target="$video_dir/$choice"
[[ -f "$target" ]] || die "not found: $target"
[[ "$target" != "$current" ]] || exit 0

jq -nc --arg target "$target" '{command: ["loadfile", $target, "replace"]}' |
  send_to_mpv "$socket" >/dev/null
