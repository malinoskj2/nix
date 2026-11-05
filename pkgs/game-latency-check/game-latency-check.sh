#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

app_id=''
game_pid=''
instance_arg=''
sample_seconds=5
delay_seconds=0
json_output=0

scope=system
report_file=''
signature=''
instance=''
windows='[]'
topology='[]'
filter_file=${GAME_LATENCY_FILTER:-${BASH_SOURCE[0]%/*}/presentation.jq}

readonly thread_limit=4096 ancestry_limit=12
readonly cpu_list='def cpus: split(",") | map(split("-") | map(tonumber) | if length == 1 then .[0] else range(.[0]; .[1] + 1) end);'

usage() {
  cat <<'EOF'
Usage: game-latency-check [STEAM_APP_ID|steam_app_ID] [options]
       game-latency-check --pid PID [options]

Read-only Hyprland/Linux latency diagnostics. Omit the ID to discover running
steam_app_* windows. Native/custom-class games can be selected with --pid.

  --pid PID             Select the window's Linux process PID
  --instance SIGNATURE  Select an exact physical Hyprland instance
  --seconds N           Sample presentation for 1–60 seconds (default: 5)
  --delay N             Wait 0–60 seconds so you can return to gameplay
  --json                Output structured observations/findings
  -h, --help            Show this help

No focus changes, screenshots, tuning, GameMode activation or game termination.
Checks are observations, not measured input latency. Ctrl-C stops the check.
EOF
}

die() {
  if ((json_output)); then
    jq -n --arg error "$*" '{error:$error}'
  else
    printf 'game-latency-check: %s\n' "$*" >&2
  fi
  exit 2
}

parse_args() {
  while (($#)); do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --json)
        json_output=1
        shift
        ;;
      --pid | --instance | --seconds | --delay)
        (($# >= 2)) || die "$1 requires a value"
        case "$1" in
          --pid) game_pid=$2 ;;
          --instance) instance_arg=$2 ;;
          --seconds) sample_seconds=$2 ;;
          --delay) delay_seconds=$2 ;;
        esac
        shift 2
        ;;
      -*) die "Unknown option: $1" ;;
      *)
        [[ -z $app_id ]] || die 'Choose one Steam app ID'
        app_id=${1#steam_app_}
        shift
        ;;
    esac
  done
  [[ -z $app_id || $app_id =~ ^[1-9][0-9]*$ ]] || die 'Use a positive Steam app ID or steam_app_ID'
  [[ -z $game_pid || $game_pid =~ ^[1-9][0-9]*$ ]] || die 'PID must be positive'
  [[ -z $app_id || -z $game_pid ]] || die 'Choose either an app ID or --pid'
  [[ $sample_seconds =~ ^([1-9]|[1-5][0-9]|60)$ ]] || die '--seconds must be 1–60'
  [[ $delay_seconds =~ ^(0|[1-9]|[1-5][0-9]|60)$ ]] || die '--delay must be 0–60'
}

# Every external probe is bounded. D-Bus queries below explicitly forbid activation.
run() { timeout --foreground --kill-after=1 3 "$@" 2>/dev/null; }
hypr() { run hyprctl -i "$signature" -j "$@"; }
read_file() { if [[ -r $1 ]]; then cat -- "$1" 2>/dev/null || true; fi; }
read_link() { readlink -- "$1" 2>/dev/null || true; }
json_array() { printf '%s\n' "$@" | jq -sc '.'; }

record() {
  jq -cn --arg kind "$1" --arg scope "$scope" --argjson data "$2" '{kind:$kind,scope:$scope,data:$data}' >>"$report_file"
}
emit_json() {
  record finding "$(jq -cn --arg status "$1" --arg check "$2" --argjson detail "$3" '{status:$status,check:$check,detail:$detail}')"
}
emit() { emit_json "$1" "$2" "$(jq -cn --arg detail "$3" '$detail')"; }
probe() {
  local check=$1 output
  shift
  if output=$(run "$@"); then
    emit INFO "$check" "${output:-No output}"
  else
    emit UNKNOWN "$check" 'Unavailable, insufficient permissions or timed out'
  fi
}
bus() { run busctl --user --auto-start=no call "$@"; }
gamemode() { bus com.feralinteractive.GameMode /com/feralinteractive/GameMode com.feralinteractive.GameMode "$@"; }

has_physical_output() {
  jq -e 'any(.[]; .disabled != true and (.name | test("^(DP|HDMI-A|eDP|DVI-[DI]|VGA|LVDS)-[0-9]+$")))' >/dev/null
}

choose_instance() {
  local instances candidate monitors count candidates=()
  instances=$(run hyprctl instances -j) || die 'Cannot list Hyprland instances'
  jq -e 'type == "array"' <<<"$instances" >/dev/null || die 'Unsupported Hyprland instance response'
  while IFS= read -r candidate; do
    signature=$(jq -r .instance <<<"$candidate")
    [[ -z $instance_arg || $signature == "$instance_arg" ]] || continue
    if monitors=$(hypr monitors) && has_physical_output <<<"$monitors"; then candidates+=("$candidate"); fi
  done < <(jq -c '.[]' <<<"$instances")
  count=${#candidates[@]}
  ((count == 1)) || die "Found $count matching physical sessions. Use --instance with an exact signature; nested/headless sessions are excluded."
  instance=${candidates[0]}
  signature=$(jq -r .instance <<<"$instance")
}

environment_value() {
  local pid=$1 key=$2 entry
  [[ -r /proc/$pid/environ ]] || return 0
  while IFS= read -r -d '' entry; do
    if [[ ${entry%%=*} == "$key" ]]; then
      printf '%s' "${entry#*=}"
      return 0
    fi
  done <"/proc/$pid/environ"
}

bind_user_bus() {
  local pid uid runtime address
  pid=$(jq -r .pid <<<"$instance")
  uid=$(awk '/^Uid:/ {print $2}' "/proc/$pid/status" 2>/dev/null) || die 'Cannot inspect the physical compositor process'
  [[ $uid == "$(id -u)" ]] || die 'Run this as the physical desktop user'
  runtime=$(environment_value "$pid" XDG_RUNTIME_DIR)
  address=$(environment_value "$pid" DBUS_SESSION_BUS_ADDRESS)
  export DBUS_SESSION_BUS_ADDRESS=${address:-unix:path=${runtime:-/run/user/$uid}/bus}
}

select_games() {
  jq -c --arg app "$app_id" --arg pid "$game_pid" '
    def steam_id: [(.class // ""), (.initialClass // "")]
      | map(select(test("^steam_app_[1-9][0-9]*$")) | sub("^steam_app_"; "")) | first;
    [.[] | select(.mapped != false and .hidden != true and (.pid | type == "number") and .pid > 0)
      | . + {app_id: steam_id}
      | select(if $pid != "" then .pid == ($pid|tonumber) elif $app != "" then .app_id == $app else .app_id != null end)]'
}

process_start() {
  local stat rest values
  stat=$(read_file "/proc/$1/stat")
  [[ -n $stat ]] || return 0
  rest=${stat##*) }
  read -ra values <<<"$rest"
  printf '%s' "${values[19]:-}"
}

record_windows() {
  local window pid seed rows=()
  while IFS= read -r window; do
    pid=$(jq -r .pid <<<"$window")
    seed=$(process_start "$pid")
    window=$(jq -c --arg seed "$seed" '{address,pid,class,initialClass,title,monitor,workspace,fullscreen,xwayland,size,at,contentType,tearingHint,app_id,process_start:$seed}' <<<"$window")
    rows+=("$window")
    scope=game-$(jq -r .address <<<"$window")
    record window "$window"
  done < <(jq -c '.[]' <<<"$windows")
  windows=$(json_array "${rows[@]}")
}

sample_presentation() {
  local clients monitors active queried window sample start=$SECONDS
  while true; do
    queried=0
    if monitors=$(hypr monitors) && active=$(hypr activewindow) && clients=$(hypr clients); then queried=1; fi
    while IFS= read -r window; do
      scope=game-$(jq -r .address <<<"$window")
      if ((!queried)); then
        sample='{"error":"Presentation query unavailable or timed out"}'
      elif ! sample=$(jq -cn --argjson clients "$clients" --argjson monitors "$monitors" --argjson active "$active" \
        --argjson window "$window" --argjson now "$(date +%s.%N)" -f "$filter_file"); then
        sample='{"error":"Unsupported presentation response"}'
      fi
      record sample "$sample"
    done < <(jq -c '.[]' <<<"$windows")
    ((SECONDS - start < sample_seconds - 1)) || break
    sleep 1
  done
}

attribution_check() {
  local key=$1 label=$2 observed=$3 focused_count=$4 summary known successes status=UNKNOWN
  summary=$(jq -c --arg key "$key" '[.[][$key] | select(type == "boolean")] | {known:length, successes:map(select(. == true))|length}' <<<"$observed")
  known=$(jq -r .known <<<"$summary")
  successes=$(jq -r .successes <<<"$summary")
  if ((focused_count > 0 && known > 0)); then
    if ((successes == known)); then status=OK; else status=WARN; fi
  fi
  emit "$status" "$label" "Active for this window in $successes/$known attributable observations"
}

summarise_presentation() {
  local samples focused focused_count observed errors key blockers
  samples=$(jq -sc --arg scope "$scope" '[.[] | select(.kind == "sample" and .scope == $scope) | .data]' "$report_file")
  focused=$(jq -c '[.[] | select(.focused == true and .workspace_visible == true)]' <<<"$samples")
  focused_count=$(jq length <<<"$focused")
  observed=$focused
  ((focused_count > 0)) || observed=$samples
  emit INFO 'Gameplay context' "$focused_count/$(jq length <<<"$samples") focused, visible observations. Menus, cursor visibility and normal gameplay cannot be distinguished automatically."
  errors=$(jq '[.[]|select(.error != null)]|length' <<<"$samples")
  ((errors == 0)) || emit UNKNOWN 'Sample coverage' "$errors presentation queries/window observations were unavailable"
  attribution_check tearing Tearing "$observed" "$focused_count"
  attribution_check scanout 'Direct scanout' "$observed" "$focused_count"
  for key in solitaryBlockedBy tearingBlockedBy directScanoutBlockedBy; do
    blockers=$(jq -c --arg key "$key" '[.[][$key]|select(. != null)]|unique' <<<"$observed")
    if [[ $blockers == '[]' ]]; then
      emit UNKNOWN "$key" 'Not exported by this build'
    else
      emit_json INFO "$key" "$blockers"
    fi
  done
  if jq -e 'any(.[]; (.directScanoutBlockedBy|tostring|contains("SW")))' <<<"$observed" >/dev/null; then
    emit INFO 'Software-cursor/render blocker' 'SW does not mean CPU rendering. A visible software cursor can block scanout while compositing still tears; hidden-cursor shooter gameplay can avoid this blocker.'
  fi
  if jq -e 'any(.[]; (.tearingBlockedBy|tostring|contains("HW_CURSOR")))' <<<"$observed" >/dev/null; then
    emit INFO 'Hardware-cursor blocker' 'Cursor updates plus tearing are restricted on the inspected display path. Async-flip capability alone does not justify removing guards.'
  fi
}

selected_environment() {
  local pid=$1 entry key value rows=()
  if [[ ! -r /proc/$pid/environ ]]; then
    emit UNKNOWN 'Launch environment' '/proc environment inaccessible'
    return
  fi
  while IFS= read -r -d '' entry; do
    key=${entry%%=*}
    value=${entry#*=}
    case "$key" in
      SteamAppId | SteamGameId | LD_PRELOAD | \
        DXVK_FRAME_RATE | __GL_SYNC_TO_VBLANK | __GL_MaxFramesAllowed | __GL_VRR_ALLOWED | vblank_mode | \
        PROTON_ENABLE_WAYLAND | SDL_VIDEODRIVER | MANGOHUD | ENABLE_GAMESCOPE_WSI | GAMESCOPE_WAYLAND_DISPLAY)
        rows+=("$(jq -cn --arg key "$key" --arg value "$value" '{key:$key,value:$value}')")
        ;;
      MANGOHUD_CONFIG)
        value=$(jq -cn --arg value "$value" '$value|split(",")|map(select(test("^(fps_limit|no_display)=")))|join(",")')
        rows+=("$(jq -cn --arg key "$key" --argjson value "$value" '{key:$key,value:$value}')")
        ;;
      DXVK_CONFIG)
        value=$(jq -cn --arg value "$value" '$value|split(";")|map(select(test("maxFrameRate\\s*=")))|join(";")')
        rows+=("$(jq -cn --arg key "$key" --argjson value "$value" '{key:$key,value:$value}')")
        ;;
    esac
  done <"/proc/$pid/environ"
  emit_json INFO 'Selected launch/presentation environment' "$(printf '%s\n' "${rows[@]}" | jq -s 'from_entries')"
}

cache_topology() {
  local path shared size bytes rows=()
  for path in /sys/devices/system/cpu/cpu[0-9]*/cache/index*; do
    [[ $(read_file "$path/level") == 3 ]] || continue
    shared=$(read_file "$path/shared_cpu_list")
    size=$(read_file "$path/size")
    case "$size" in
      *K) bytes=$((${size%K} * 1024)) ;;
      *M) bytes=$((${size%M} * 1024 * 1024)) ;;
      *) continue ;;
    esac
    rows+=("$(jq -cn --arg shared "$shared" --argjson bytes "$bytes" '{logical_cpus:$shared,bytes:$bytes}')")
  done
  printf '%s\n' "${rows[@]}" | jq -sc 'unique_by(.logical_cpus)'
}

gamemode_client_report() {
  local pid=$1 libraries response
  if [[ -r /proc/$pid/maps ]]; then
    libraries=$(awk '/\/libgamemode(auto)?\.so/ {print $NF}' "/proc/$pid/maps" | sort -u | jq -Rsc 'split("\n")|map(select(length>0))')
    emit_json INFO 'Mapped GameMode libraries' "$libraries"
  else
    libraries='[]'
    emit UNKNOWN 'Mapped GameMode libraries' '/proc maps inaccessible'
  fi
  if ! response=$(gamemode QueryStatus i "$pid"); then
    emit UNKNOWN 'GameMode registration' 'Daemon stopped, bus inaccessible, denied or timed out; this check does not activate it'
    return
  fi
  case "$response" in
    'i 2')
      emit OK 'GameMode registration' 'This PID is directly registered'
      if jq -e 'length>0 and (any(.[];contains("/libgamemode.so"))|not)' <<<"$libraries" >/dev/null; then
        emit WARN 'GameMode companion library' 'Auto loader is mapped without libgamemode.so'
      fi
      ;;
    'i 1') emit WARN 'GameMode registration' 'Active for another PID; this PID is not registered' ;;
    'i 0') emit WARN 'GameMode registration' Inactive ;;
    *) emit UNKNOWN 'GameMode registration' 'Query failed or returned an unknown status' ;;
  esac
}

ancestry_report() {
  local parent=$1 depth name exe rows=()
  for ((depth = 0; depth < ancestry_limit; depth++)); do
    [[ -r /proc/$parent/status ]] || break
    name=$(read_file "/proc/$parent/comm")
    exe=$(read_link "/proc/$parent/exe")
    rows+=("$(jq -cn --argjson pid "$parent" --arg name "$name" --arg exe "$exe" '{pid:$pid,name:$name,executable:$exe}')")
    if [[ $exe == *gamescope* || $name == gamescope ]]; then
      emit WARN 'Gamescope wrapper' 'Nested Gamescope remains in the focused presentation path too'
    fi
    parent=$(awk '/^PPid:/ {print $2}' "/proc/$parent/status" 2>/dev/null) || break
    if [[ ! $parent =~ ^[0-9]+$ ]] || ((parent <= 1)); then break; fi
  done
  emit_json INFO 'Launch ancestry' "$(json_array "${rows[@]}")"
}

cache_placement_report() {
  local summary=$1 larger excluded
  [[ $(jq 'map(.bytes)|unique|length' <<<"$topology") -gt 1 ]] || return 0
  larger=$(jq -c "$cpu_list"' max_by(.bytes).bytes as $max | [.[] | select(.bytes == $max) | .logical_cpus | cpus[]] | unique' <<<"$topology")
  excluded=$(jq --argjson larger "$larger" "$cpu_list"'
    [.affinity[] | select((.value | cpus) as $allowed | ($allowed - $larger | length) == ($allowed | length)) | .threads]
    | add // 0' <<<"$summary")
  if ((excluded > 0)); then
    emit WARN 'Larger L3 cache placement' "$excluded inspected thread masks exclude the larger-cache logical CPUs $larger"
  else
    emit INFO 'Larger L3 cache placement' "Larger-cache logical CPUs: $larger. Eligibility does not prove actual V-Cache placement."
  fi
}

thread_report() {
  local pid=$1 listing tid nice scheduler cpu affinity priority rows=() count=0 observed=0 summary
  if ! listing=$(run ps -L -p "$pid" -o tid=,ni=,cls=,psr=); then
    emit UNKNOWN 'Thread scheduling' 'Process exited or threads inaccessible'
    return
  fi
  while read -r tid nice scheduler cpu; do
    [[ $tid =~ ^[0-9]+$ ]] || continue
    observed=$((observed + 1))
    ((count < thread_limit)) || continue
    affinity=$(awk '/^Cpus_allowed_list:/ {print $2}' "/proc/$pid/task/$tid/status" 2>/dev/null) || continue
    [[ -n $affinity ]] || continue
    priority=$(run ionice -p "$tid") || priority=unavailable
    rows+=("$affinity"$'\t'"$nice"$'\t'"$scheduler"$'\t'"$cpu"$'\t'"$priority")
    count=$((count + 1))
  done <<<"$listing"
  summary=$(printf '%s\n' "${rows[@]}" | jq -Rsc --argjson observed "$observed" --argjson inspected "$count" '
    split("\n") | map(select(length>0) | split("\t") | {affinity:.[0],nice:.[1],scheduler:.[2],cpu:.[3],ioprio:.[4]}) as $rows
    | {observed_threads:$observed,inspected_threads:$inspected}
      + (["affinity","nice","scheduler","cpu","ioprio"]
        | map(. as $key | {key:$key,value:($rows|group_by(.[$key])|map({value:.[0][$key],threads:length}))})
        | from_entries)')
  if ((count > 0)); then
    emit_json INFO 'Thread scheduling' "$summary"
  else
    emit UNKNOWN 'Thread scheduling' 'No thread could be inspected'
  fi
  ((count == observed)) || emit UNKNOWN 'Thread coverage' "Threads exited, were inaccessible or exceeded the $thread_limit-thread inspection limit"
  emit INFO 'I/O priority interpretation' 'none: prio 0 is unset and derives effective priority from niceness; best-effort: prio 0 is an explicit boost. Affinity includes logical CPUs/SMT threads.'
  if jq -e 'any(.scheduler[];.value=="IDL") or any(.ioprio[];.value|startswith("idle"))' <<<"$summary" >/dev/null; then
    emit WARN 'Idle-priority threads' 'Review whether idle CPU/I/O scheduling is intentional'
  fi
  cache_placement_report "$summary"
}

process_report() {
  local window=$1 pid expected
  pid=$(jq -r .pid <<<"$window")
  expected=$(jq -r .process_start <<<"$window")
  if [[ -z $expected || $(process_start "$pid") != "$expected" ]]; then
    emit UNKNOWN Process 'Exited, PID reused or /proc inaccessible'
    return
  fi
  emit INFO Executable "$(read_link "/proc/$pid/exe")"
  gamemode_client_report "$pid"
  selected_environment "$pid"
  ancestry_report "$pid"
  thread_report "$pid"
  [[ $(process_start "$pid") == "$expected" ]] || emit UNKNOWN 'Process identity changed' 'Discard this process snapshot; the game exited or its PID was reused'
}

compositor_report() {
  local option output options=(
    general:allow_tearing render:direct_scanout
    cursor:no_hardware_cursors cursor:no_break_fs_vrr
    input:accel_profile input:force_no_accel input:sensitivity input:follow_mouse
    misc:vrr
  )
  scope=compositor
  probe 'Hyprland build' hyprctl -i "$signature" version
  emit INFO 'Running compositor executable' "$(read_link "/proc/$(jq -r .pid <<<"$instance")/exe")"
  for option in "${options[@]}"; do
    if output=$(hypr getoption "$option") &&
      jq -e 'type=="object" and (has("int") or has("bool") or has("str") or has("float"))' <<<"$output" >/dev/null; then
      emit_json INFO "$option" "$output"
    else
      emit UNKNOWN "$option" 'Unsupported option or inaccessible instance'
    fi
  done
  for option in devices layers; do
    if output=$(hypr "$option") && jq -e . <<<"$output" >/dev/null; then
      emit_json INFO "$option" "$output"
    else
      emit UNKNOWN "$option" 'Query unavailable'
    fi
  done
  emit UNKNOWN 'Effective mouse overrides' 'Global settings and device defaultSpeed do not establish effective per-device acceleration/sensitivity; review the mouse rules'
}

xwayland_report() {
  local pid child display='' args auth output primary children
  jq -e 'any(.[];.xwayland==true)' <<<"$windows" >/dev/null || return 0
  scope=compositor
  pid=$(jq -r .pid <<<"$instance")
  read -ra children <<<"$(read_file "/proc/$pid/task/$pid/children")"
  for child in "${children[@]}"; do
    [[ $(read_file "/proc/$child/comm") == Xwayland ]] || continue
    [[ -r /proc/$child/cmdline ]] || continue
    while IFS= read -r -d '' args; do [[ $args =~ ^:[0-9]+$ ]] && display=$args; done <"/proc/$child/cmdline"
    [[ -z $display ]] || break
  done
  if [[ -z $display ]]; then
    emit UNKNOWN 'XWayland primary output' "Cannot identify this compositor's XWayland display; inherited DISPLAY is not trusted"
    return
  fi
  auth=$(environment_value "$pid" XAUTHORITY)
  if ! output=$(DISPLAY=$display XAUTHORITY=$auth run xrandr --listmonitors); then
    emit UNKNOWN 'XWayland primary output' 'X display query unavailable'
    return
  fi
  primary=$(awk '$2 ~ /\*/ {print $NF}' <<<"$output")
  if [[ -z $primary ]]; then
    emit WARN 'XWayland primary output' "$output"
  else
    emit INFO 'XWayland primary output' "$output"
  fi
  emit INFO 'Wine display selection' 'An unset/unexpected XWayland primary can affect cached resolution. Outer window size does not prove the inner render surface fills it.'
}

cpu_report() {
  local path scx_state scx_ops policies=()
  probe 'Linux kernel' uname -r
  emit INFO 'Kernel scheduling flags' "$(awk '{for(i=1;i<=NF;i++)if($i~/^(preempt|amd_pstate)=/)print $i}' /proc/cmdline)"
  emit_json INFO 'L3 cache topology' "$topology"
  scx_state=$(read_file /sys/kernel/sched_ext/state)
  scx_ops=$(read_file /sys/kernel/sched_ext/root/ops)
  if [[ -n $scx_state ]]; then
    emit INFO 'sched-ext state' "state=$scx_state ops=$scx_ops"
  else
    emit UNKNOWN 'sched-ext state' 'sched-ext state not accessible'
  fi
  for path in /sys/devices/system/cpu/cpufreq/policy*; do
    policies+=("$(jq -cn --arg policy "${path##*/}" --arg driver "$(read_file "$path/scaling_driver")" \
      --arg governor "$(read_file "$path/scaling_governor")" --arg epp "$(read_file "$path/energy_performance_preference")" \
      --arg cpus "$(read_file "$path/affected_cpus")" '{policy:$policy,driver:$driver,governor:$governor,epp:$epp,cpus:$cpus}')")
  done
  if ((${#policies[@]})); then
    emit_json INFO 'CPU frequency policy' "$(json_array "${policies[@]}")"
  else
    emit UNKNOWN 'CPU frequency policy' 'No accessible cpufreq policies'
  fi
  emit INFO 'CPU policy interpretation' 'powersave under active AMD P-state can still boost; governor/EPP alone does not establish a CPU bottleneck'
}

gamemode_daemon_report() {
  local groups owner daemon running deployed=''
  groups=$(id -nG)
  if [[ " $groups " == *' gamemode '* ]]; then
    emit OK 'GameMode group' "$groups"
  else
    emit WARN 'GameMode group' "Effective groups: $groups. New group membership requires a fresh login."
  fi
  if ! owner=$(bus org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetConnectionUnixProcessID s com.feralinteractive.GameMode) ||
    [[ ! $owner =~ ^u\ ([0-9]+)$ ]]; then
    emit UNKNOWN 'GameMode daemon executable' 'No accessible bus owner; daemon not started by this check'
    return
  fi
  daemon=${BASH_REMATCH[1]}
  running=$(read_link "/proc/$daemon/exe")
  [[ ! -x /run/current-system/sw/bin/gamemoded ]] || deployed=$(readlink -f /run/current-system/sw/bin/gamemoded)
  if [[ -n $running && -n $deployed && $running != "$deployed" ]]; then
    emit WARN 'GameMode daemon executable' "running=$running deployed=$deployed"
  else
    emit INFO 'GameMode daemon executable' "running=$running deployed=$deployed"
  fi
}

gamemode_clients_report() {
  local output pid _object name clients=() helpers=()
  if ! output=$(gamemode ListGames); then
    emit UNKNOWN 'Registered GameMode clients' 'Query unavailable'
    return
  fi
  while read -r pid _object; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    name=$(read_link "/proc/$pid/exe")
    name=${name##*/}
    clients+=("$(jq -cn --argjson pid "$pid" --arg name "$name" '{pid:$pid,name:$name}')")
    case "$name" in
      steam | steamwebhelper | steamservice | steam_monitor | steam-runtime-launcher-service | steam-runtime-supervisor)
        helpers+=("$pid:$name")
        ;;
    esac
  done < <(awk '{
    while (match($0, /([0-9]+) "(\/[^"]+)"/, a)) {
      print a[1], a[2]
      $0 = substr($0, RSTART + RLENGTH)
    }
  }' <<<"$output")
  emit_json INFO 'Registered GameMode clients' "$(json_array "${clients[@]}")"
  ((${#helpers[@]} == 0)) || emit WARN 'Persistent Steam helper registration' "${helpers[*]}"
}

gamemode_log_report() {
  local output line failures=() notes=()
  if ! output=$(run journalctl --user -u gamemoded -b --since=-10min -n 80 --no-pager -o cat); then
    emit UNKNOWN 'Recent GameMode failures' 'Journal inaccessible'
    return
  fi
  while IFS= read -r line; do
    if [[ $line == *'Skipping ioprio'* ]]; then
      notes+=("$line")
    elif grep -qiE 'error|failed|denied' <<<"$line"; then
      failures+=("$line")
    fi
  done <<<"$output"
  if ((${#failures[@]})); then
    emit WARN 'Recent GameMode failures' "${failures[*]}"
  else
    emit INFO 'Recent GameMode failures' 'No matching errors in bounded log window; journal access may be incomplete'
  fi
  ((${#notes[@]} == 0)) || emit INFO 'Recent I/O priority notices' "${notes[*]}"
}

gpu_report() {
  local output driver
  if output=$(run journalctl -k -b --since=-10min -n 150 --no-pager -o cat); then
    output=$(grep -iE 'NVRM.*Xid|GPU.*(hang|reset|fault)|amdgpu.*(timeout|reset)|Out of memory|oom-kill' <<<"$output" || true)
    if [[ -n $output ]]; then
      emit WARN 'Recent GPU/kernel failures' "$output"
    else
      emit INFO 'Recent GPU/kernel failures' 'No matching errors in bounded log window; journal access may be incomplete'
    fi
  else
    emit UNKNOWN 'Recent GPU/kernel failures' 'Kernel journal inaccessible'
  fi
  driver=$(read_file /sys/module/nvidia/version)
  if [[ -n $driver ]]; then
    emit INFO 'NVIDIA driver' "$driver"
    probe 'NVIDIA GPU snapshot' nvidia-smi --query-gpu=name,driver_version,pstate,utilization.gpu,clocks.gr,clocks.mem,power.draw --format=csv,noheader
  fi
}

mouse_report() {
  local event properties device name speed control power interval ep endpoints ancestor rows=()
  for event in /sys/class/input/event*; do
    properties=$(run udevadm info --query=property "--path=$event") || continue
    grep -qx 'ID_INPUT_MOUSE=1' <<<"$properties" || continue
    device=$(readlink -f "$event/device")
    name=$(read_file "$device/name")
    speed='' control='' power='' endpoints=()
    ancestor=$device
    while [[ $ancestor == /sys/* ]]; do
      for ep in "$ancestor"/ep_*; do
        if [[ $(read_file "$ep/type") == Interrupt && $(read_file "$ep/direction") == in ]]; then
          interval=$(read_file "$ep/interval")
          endpoints+=("$(jq -cn --arg interval "$interval" --arg bInterval "$(read_file "$ep/bInterval")" '{interval:$interval,bInterval:$bInterval}')")
        fi
      done
      if [[ -r $ancestor/speed && -r $ancestor/busnum ]]; then
        speed=$(read_file "$ancestor/speed")
        control=$(read_file "$ancestor/power/control")
        power=$(read_file "$ancestor/power/runtime_status")
        break
      fi
      ancestor=${ancestor%/*}
    done
    rows+=("$(jq -cn --arg event "${event##*/}" --arg name "$name" --arg sysfs "$device" \
      --arg speed "$speed" --arg control "$control" --arg power "$power" --argjson endpoints "$(json_array "${endpoints[@]}")" \
      '{event:$event,name:$name,sysfs:$sysfs,usb:{speed_mbps:$speed,power_control:$control,runtime_status:$power},interrupt_endpoints:$endpoints}')")
  done
  if ((${#rows[@]})); then
    emit_json INFO 'Mouse USB/power snapshot' "$(json_array "${rows[@]}")"
  else
    emit UNKNOWN 'Mouse USB/power snapshot' 'No accessible udev mouse devices'
  fi
  emit INFO 'Mouse interpretation' 'USB intervals are nominal, not delivered polling rate. auto power control with active runtime status is not proof of a delay. Match these devices to the mouse used to play.'
}

drm_report() {
  local card path connected output found=0
  for card in /sys/class/drm/card[0-9]*; do
    [[ ${card##*/} =~ ^card[0-9]+$ ]] || continue
    connected=0
    for path in "$card"-*; do [[ $(read_file "$path/status") != connected ]] || connected=1; done
    ((connected)) || continue
    found=1
    if output=$(run drm_info -j "/dev/dri/${card##*/}") &&
      output=$(jq -ce 'to_entries|map({card:.key,driver:.value.driver.name,caps:(.value.driver.caps|{ASYNC_PAGE_FLIP,ATOMIC_ASYNC_PAGE_FLIP,CURSOR_WIDTH,CURSOR_HEIGHT})})|select(length>0)' <<<"$output"); then
      emit_json INFO 'DRM capabilities' "$output"
    else
      emit UNKNOWN 'DRM capabilities' "${card##*/}: inaccessible or unsupported response"
    fi
  done
  ((found)) || emit UNKNOWN 'DRM capabilities' 'No connected DRM card found'
  emit INFO 'DRM interpretation' 'Capabilities advertise support, not current frame use or arbitrary cursor updates during tearing. drm_info opens its own read-only descriptor; it does not set display modes or DRM master.'
}

system_report() {
  scope=system
  cpu_report
  gamemode_daemon_report
  gamemode_clients_report
  gamemode_log_report
  gpu_report
  mouse_report
  drm_report
}

swap_pages() { awk '/^pswp(in|out) / {print $2}' /proc/vmstat | jq -sc '.'; }

activity_report() {
  local swap_before=$1 swap_after delta resource stall
  scope=system
  swap_after=$(swap_pages)
  delta=$(jq -cn --argjson before "$swap_before" --argjson after "$swap_after" '{pswpin:($after[0]-$before[0]),pswpout:($after[1]-$before[1])}')
  if jq -e 'any(.[];.>0)' <<<"$delta" >/dev/null; then
    emit_json WARN 'Swap activity during check (pages)' "$delta"
  else
    emit_json INFO 'Swap activity during check (pages)' "$delta"
  fi
  for resource in cpu memory io; do
    stall=$(read_file "/proc/pressure/$resource")
    if [[ -n $stall ]]; then
      emit INFO "$resource pressure stall snapshot" "$stall"
    else
      emit UNKNOWN "$resource pressure stall snapshot" 'Pressure telemetry inaccessible'
    fi
  done
}

render_report() {
  jq -s --argjson instance "$instance" '
    . as $rows | {instance:$instance,
      games:[$rows[]|select(.kind=="window")|. as $w|
        {window:$w.data,app_id:$w.data.app_id,
          checks:[$rows[]|select(.scope==$w.scope and .kind=="finding")|.data],
          samples:[$rows[]|select(.scope==$w.scope and .kind=="sample")|.data]}],
      compositor:[$rows[]|select(.scope=="compositor" and .kind=="finding")|.data],
      system:[$rows[]|select(.scope=="system" and .kind=="finding")|.data],
      limitations:["In-game VSync, Reflex, frame generation, FPS caps and raw/relative input require game-specific verification.",
        "Effective mouse overrides, Wine child render geometry and measured input delivery are not established by these checks.",
        "GameMode registration does not prove every optimisation succeeded; exit-time cleanup/restoration is not exercised.",
        "GPU clocks/utilisation and USB intervals are snapshots/specifications, not frame-time or click-to-photon measurements. These checks do not prove zero added latency."]}' "$report_file" |
    if ((json_output)); then cat; else
      jq -r 'def check: "  [\(.status)] \(.check): \(if .detail|type=="string" then .detail else .detail|tojson end)";
      (.games[]|"\nGame \(.app_id//"(PID selection)") — PID \(.window.pid) — \(.window.title|tojson)",
        "  Window: \(.window|tojson)",(.checks[]|check),"  Latest presentation: \(.samples[-1]|tojson)"),
      "\nCompositor",(.compositor[]|check),"\nLinux, GameMode and mouse",(.system[]|check),
      "\nStill requires verification",(.limitations[]|"  - "+.)'
    fi
}

main() {
  local clients window swap_before
  parse_args "$@"
  if ((delay_seconds)); then
    printf 'Starting in %ss; return to gameplay. Ctrl-C stops the check.\n' "$delay_seconds" >&2
    sleep "$delay_seconds"
  fi
  choose_instance
  bind_user_bus
  clients=$(hypr clients) || die 'Cannot query game windows'
  windows=$(select_games <<<"$clients") || die 'Unsupported game window response'
  [[ $windows != '[]' ]] || die 'No matching running game window. For native/custom classes, use --pid with the window PID.'
  report_file=$(mktemp -t game-latency-check.XXXXXXXX)
  trap 'rm -f -- "$report_file"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf 'Checking %s window(s); sampling for about %ss.\n' "$(jq length <<<"$windows")" "$sample_seconds" >&2
  record_windows
  swap_before=$(swap_pages)
  sample_presentation
  topology=$(cache_topology)
  while IFS= read -r window; do
    scope=game-$(jq -r .address <<<"$window")
    summarise_presentation
    process_report "$window"
  done < <(jq -c '.[]' <<<"$windows")
  compositor_report
  xwayland_report
  system_report
  activity_report "$swap_before"
  render_report
}

# Sourcing exposes pure helpers to tests without querying the desktop.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
