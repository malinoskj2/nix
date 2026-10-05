#!/usr/bin/env bash
# Each monitor named gets a video that differs from its last one and from every other monitor's.
# With no monitor named, the monitors that already have a video get a new one.

readonly video_dir="$HOME/.wallpapers/video"
readonly state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper"
readonly state_file="$state_dir/assignments.json"

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
# wallpaper-select and a wallpaper-play per monitor write the file too.
exec 9>"$state_dir/lock"
flock 9

if ! jq -e '.assignments | type == "object"' "$state_file" >/dev/null 2>&1; then
  printf '{"assignments":{}}\n' >"$state_file"
fi

connectors=("$@")
if ((${#connectors[@]} == 0)); then
  mapfile -t connectors < <(jq -r '.assignments | keys[]' "$state_file")
fi
mapfile -t videos < <(
  find "$video_dir" -maxdepth 1 -type f -regextype egrep -iregex '.*\.(mp4|webm|mkv|mov|gif)' |
    shuf
)
((${#connectors[@]} > 0 && ${#videos[@]} > 0)) || exit 0

declare -A rerolled=()
for connector in "${connectors[@]}"; do
  rerolled["$connector"]=1
done

declare -A used_videos=()
while IFS=$'\t' read -r connector video; do
  [[ -n "${rerolled[$connector]:-}" ]] || used_videos["$video"]=1
done < <(jq -r '.assignments | to_entries[] | [.key, .value] | @tsv' "$state_file")

assignments='{}'
for connector in "${connectors[@]}"; do
  previous="$(jq -r --arg connector "$connector" '.assignments[$connector] // ""' "$state_file")"
  video="$(pick_video "$previous")"
  used_videos["$video"]=1
  assignments="$(
    jq --arg connector "$connector" --arg video "$video" '.[$connector] = $video' <<<"$assignments"
  )"
done

temp_file="$(mktemp "$state_file.XXXXXX")"
jq --argjson assignments "$assignments" '.assignments += $assignments' "$state_file" >"$temp_file" &&
  mv "$temp_file" "$state_file"
