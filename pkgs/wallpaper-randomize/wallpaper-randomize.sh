#!/usr/bin/env bash

readonly video_dir="$HOME/.wallpapers/video"
readonly state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper"
readonly state_file="$state_dir/assignments.json"

# A monitor gets a video that differs from its last one and, while there are enough to go round,
# from every other monitor's.
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

mkdir -p "$state_dir"
# wallpaper-select writes the file too, and every monitor's wallpaper-play may run this at once.
exec 9>"$state_dir/lock"
flock 9

if ! jq -e '.assignments | type == "object"' "$state_file" >/dev/null 2>&1; then
  printf '{"assignments":{}}\n' >"$state_file"
fi

monitors=("$@")
if ((${#monitors[@]} == 0)); then
  mapfile -t monitors < <(jq -r '.assignments | keys[]' "$state_file")
fi
mapfile -t videos < <(
  find "$video_dir" -maxdepth 1 -type f -regextype egrep -iregex '.*\.(mp4|webm|mkv|mov|gif)' |
    shuf
)
((${#monitors[@]} > 0 && ${#videos[@]} > 0)) || exit 0

declare -A reassigned=()
for monitor in "${monitors[@]}"; do
  reassigned["$monitor"]=1
done

declare -A previous_videos=() used_videos=()
while IFS=$'\t' read -r monitor video; do
  previous_videos["$monitor"]="$video"
  [[ -n "${reassigned[$monitor]:-}" ]] || used_videos["$video"]=1
done < <(jq -r '.assignments | to_entries[] | [.key, .value] | @tsv' "$state_file")

picks=()
for monitor in "${monitors[@]}"; do
  video="$(pick_video "${previous_videos[$monitor]:-}")"
  used_videos["$video"]=1
  picks+=(--arg "$monitor" "$video")
done

temp_file="$(mktemp "$state_file.XXXXXX")"
jq "${picks[@]}" '.assignments += $ARGS.named' "$state_file" >"$temp_file" &&
  mv "$temp_file" "$state_file"
