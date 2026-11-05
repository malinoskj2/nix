#!/usr/bin/env bash

readonly state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper"
readonly state_file="$state_dir/assignments.json"

die() {
  printf 'wallpaper-play: %s\n' "$*" >&2
  exit 1
}

assigned_video() {
  local monitor="$1"

  jq -r --arg monitor "$monitor" '.assignments[$monitor] // empty' "$state_file" 2>/dev/null || true
}

monitor="${1:?usage: wallpaper-play <monitor>}"

video="$(assigned_video "$monitor")"
if [[ ! -f "$video" ]]; then
  wallpaper-randomize "$monitor"
  video="$(assigned_video "$monitor")"
fi
[[ -f "$video" ]] || die "no video for $monitor"

# mpvpaper splits the options on spaces, so none may contain one. It draws on the background layer
# unless told otherwise. Without quiet, mpv's status line fills the journal.
options=(
  loop-file=inf
  panscan=1.0
  no-audio
  hwdec=auto
  "input-ipc-server=$state_dir/ipc-$monitor.sock"
  # wallpaper-autopause decides when it plays, so nothing plays unseen behind windows or the lock
  # screen.
  pause=yes
  quiet
)
exec mpvpaper -o "${options[*]}" "$monitor" "$video"
