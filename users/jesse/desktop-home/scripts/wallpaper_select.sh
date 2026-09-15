#!/usr/bin/env bash
# Pick a video from the wallpaper directory in the noctalia launcher and switch
# a monitor's running wallpaper to it (default: the focused monitor).
# Usage: wallpaper_select [monitor]
#
# Loads the file straight into mpv over the plugin's IPC socket. The plugin
# doesn't learn about it, so a noctalia restart reverts to its assignment.

VIDEO_DIR="$HOME/.wallpapers/video"
MPV_IPC_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/mpvpaper"

MON=${1:-$(hyprctl -j monitors | jq -r '.[] | select(.focused) | .name')}
SOCK="$MPV_IPC_DIR/ipc-$MON.sock"

mpv() {
	socat - "UNIX-CONNECT:$SOCK" 2>/dev/null
}

if ! printf '{"command":["get_property","path"]}\n' | mpv | jq -e '.error == "success"' >/dev/null; then
	echo "no running video wallpaper on $MON" >&2
	exit 1
fi

current=$(printf '{"command":["get_property","path"]}\n' | mpv | jq -r '.data')

choice=$(
	find "$VIDEO_DIR" -maxdepth 1 -type f -regextype egrep -iregex '.*\.(mp4|webm|mkv|mov|gif)' -printf '%f\n' |
		sort |
		while read -r f; do
			if [ "$VIDEO_DIR/$f" = "$current" ]; then echo "$f (current)"; else echo "$f"; fi
		done |
		noctalia dmenu -p "Wallpaper ($MON)"
) || true
choice=${choice% (current)}
[ -n "$choice" ] || exit 0

target="$VIDEO_DIR/$choice"
[ -f "$target" ] || {
	echo "not found: $target" >&2
	exit 1
}
[ "$target" = "$current" ] && exit 0

jq -nc --arg t "$target" '{command: ["loadfile", $t, "replace"]}' | mpv >/dev/null
