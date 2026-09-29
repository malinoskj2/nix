#!/usr/bin/env bash
# mpv starts paused: wallpaper-autopause decides when it plays, so nothing plays unseen behind
# windows or the lock screen.

readonly state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper"
readonly state_file="$state_dir/assignments.json"

assigned_video() {
  jq -r --arg monitor "$monitor" '.assignments[$monitor] // empty' "$state_file" 2>/dev/null || true
}

monitor="${1:?usage: wallpaper-play <monitor>}"

video="$(assigned_video)"
if [[ ! -f "$video" ]]; then
  wallpaper-randomize "$monitor"
  video="$(assigned_video)"
fi
if [[ ! -f "$video" ]]; then
  printf 'wallpaper-play: no video for %s\n' "$monitor" >&2
  exit 1
fi

# mpvpaper splits the options on spaces, so none may contain one. It draws on the background layer
# unless told otherwise. Without quiet, mpv's status line fills the journal.
exec mpvpaper \
  -o "loop-file=inf panscan=1.0 no-audio hwdec=auto input-ipc-server=$state_dir/ipc-$monitor.sock pause=yes quiet" \
  "$monitor" "$video"
