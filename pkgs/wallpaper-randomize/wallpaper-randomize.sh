#!/usr/bin/env bash
# Give each monitor with a Noctalia video wallpaper a random video from ~/.wallpapers/video.
#
# The script runs before Noctalia starts: the mpvpaper plugin reads assignments.json at launch and
# keeps that video until the next launch. Monitors without an existing assignment are left alone.
# Slideshow mode is forced off, since only then does the plugin poll mpv.

readonly video_dir="$HOME/.wallpapers/video"
readonly mpvpaper_dir="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/mpvpaper"
readonly state_file="$mpvpaper_dir/assignments.json"

# Prints the first entry of videos that is neither the monitor's previous video nor in
# used_videos. With too few videos, it settles for any but the previous one, then for the first.
pick_video() {
  local previous="$1"
  local video

  for video in "${videos[@]}"; do
    if [[ "$video" != "$previous" && -z "${used_videos[$video]:-}" ]]; then
      printf '%s\n' "$video"
      return
    fi
  done

  for video in "${videos[@]}"; do
    if [[ "$video" != "$previous" ]]; then
      printf '%s\n' "$video"
      return
    fi
  done

  printf '%s\n' "${videos[0]}"
}

mkdir -p "$mpvpaper_dir"
printf '{"interval":0}\n' >"$mpvpaper_dir/slideshow_override.json"

mapfile -t connectors < <(jq -r '.assignments // {} | keys[]' "$state_file" 2>/dev/null)
mapfile -t videos < <(
  find "$video_dir" -maxdepth 1 -type f -regextype egrep -iregex '.*\.(mp4|webm|mkv|mov|gif)' |
    shuf
)
((${#connectors[@]} > 0 && ${#videos[@]} > 0)) || exit 0

declare -A used_videos=()
assignments='{}'
for connector in "${connectors[@]}"; do
  previous="$(jq -r --arg connector "$connector" '.assignments[$connector]' "$state_file")"
  video="$(pick_video "$previous")"
  used_videos["$video"]=1
  assignments="$(
    jq --arg connector "$connector" --arg video "$video" '.[$connector] = $video' <<<"$assignments"
  )"
done

temp_file="$(mktemp "$state_file.XXXXXX")"
jq --argjson assignments "$assignments" '.assignments = $assignments' "$state_file" >"$temp_file" &&
  mv "$temp_file" "$state_file"
