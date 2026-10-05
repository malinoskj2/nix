#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Fixture overrides are called indirectly by the sourced diagnostic.
# shellcheck disable=SC2329
set -euo pipefail
script_dir=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
# shellcheck source=../game-latency-check.sh
source "$script_dir/game-latency-check.sh"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
fixture_window='{"address":"0xabc","class":"steam_app_730","pid":123,"workspace":{"id":5},"monitor":1,"title":"Fixture game"}'
monitor='{"id":1,"name":"DP-2","activeWorkspace":{"id":5},"solitary":"abc","directScanoutTo":"abc","activelyTearing":true,"tearingBlockedBy":[],"directScanoutBlockedBy":[]}'
tests=0

assert_json() { jq -e "$1" >/dev/null; }
passed() {
  tests=$((tests + 1))
  printf 'ok %s - %s\n' "$tests" "$1"
}
sample() {
  jq -cn --argjson window "$fixture_window" --argjson clients "[$fixture_window]" --argjson monitors "[$1]" --argjson active "$2" --argjson now 0 -f "$filter_file"
}

clients=$(jq -cn --argjson w "$fixture_window" '[$w,($w+{pid:124,class:"cs2"}),($w+{pid:125,class:"steam"}),($w+{pid:126,hidden:true})]')
select_games <<<"$clients" | assert_json 'length==1 and .[0].app_id=="730"'
app_id=999
select_games <<<"$clients" | assert_json 'length==0'
app_id='' game_pid=124
select_games <<<"$clients" | assert_json 'length==1 and .[0].class=="cs2"'
game_pid=''
passed 'discovery, Steam ID and native PID selection'

sample "$monitor" "$fixture_window" | assert_json '.tearing==true and .scanout==true'
sample "$(jq -c '.solitary="def"|.directScanoutTo="def"' <<<"$monitor")" "$fixture_window" | assert_json '.tearing==false and .scanout==false'
passed 'address normalisation and scanout attribution'

sample "$(jq -c '.directScanoutTo="0"|.directScanoutBlockedBy=["SW"]' <<<"$monitor")" "$fixture_window" | assert_json '.tearing==true and .scanout==false'
passed 'tearing and scanout are independent'

sample '{"id":1,"name":"DP-2"}' "$fixture_window" | assert_json '.tearing==null and .scanout==null and .workspace_visible==null'
passed 'missing telemetry is unknown'

report_file=$test_dir/report scope=game-fixture
record sample "$(sample "$monitor" '{"address":"0xdef"}')"
summarise_presentation
jq -s -e '[.[]|select(.kind=="finding" and (.data.check=="Tearing" or .data.check=="Direct scanout"))|.data.status]|all(.=="UNKNOWN")' "$report_file" >/dev/null
passed 'background observations cannot pass gameplay checks'

printf '[]' | { if physical; then exit 1; fi; }
printf '[{"name":"NESTED-1"}]' | { if physical; then exit 1; fi; }
printf '[%s]' "$monitor" | physical
passed 'nested/headless outputs are excluded'

(
  run() { printf '[{"instance":"nested","pid":1},{"instance":"physical","pid":2}]'; }
  hypr() { if [[ $signature == nested ]]; then printf '[{"name":"NESTED-1"}]'; else printf '[%s]' "$monitor"; fi; }
  choose_instance
  [[ $signature == physical ]]
)
passed 'physical compositor discovery ignores inherited nested session'

(
  run() { printf '[{"instance":"one","pid":1},{"instance":"two","pid":2}]'; }
  hypr() { printf '[%s]' "$monitor"; }
  instance_arg=two
  choose_instance
  [[ $signature == two ]]
)
if (
  run() { printf '[{"instance":"one"},{"instance":"two"}]'; }
  hypr() { printf '[%s]' "$monitor"; }
  choose_instance
) >/dev/null 2>&1; then exit 1; fi
passed 'ambiguous physical sessions require explicit selection'

(
  run() {
    [[ $1 == busctl && $2 == --user && $3 == --auto-start=no ]]
    [[ $* == *QueryStatus* && $* != *RegisterGame* ]]
  }
  gamemode QueryStatus i 123
)
passed 'GameMode query forbids activation and registration'

(
  parse_args steam_app_730 --seconds 1 --delay 5 --json
  [[ $app_id == 730 && $sample_seconds == 1 && $delay_seconds == 5 && $json_output == 1 ]]
)
for args in '--seconds 0' '--delay 61' '730 --pid 123' '--pid -1' 'steam_app_0'; do
  read -ra arguments <<<"$args"
  if (parse_args "${arguments[@]}") >/dev/null 2>&1; then exit 1; fi
done
passed 'argument meanings and duration bounds'

fixture_main() (
  choose_instance() {
    instance='{"instance":"physical","pid":55}'
    signature=physical
  }
  bind_user_bus() { :; }
  process_start() { printf 1234; }
  hypr() {
    case "$1" in
      clients) printf '[%s]' "$fixture_window" ;;
      monitors) printf '[%s]' "$monitor" ;;
      activewindow) printf '%s' "$fixture_window" ;;
      *)
        printf 'Unexpected query: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  }
  cache_topology() { printf '[]'; }
  process_report() { emit INFO Process fixture; }
  compositor_report() {
    scope=compositor
    emit INFO Compositor fixture
  }
  xwayland_report() { :; }
  system_report() {
    scope=system
    emit INFO Linux fixture
  }
  read_file() { printf fixture; }
  awk() { printf '0\n0\n'; }
  main "$@"
)
fixture_main 730 --seconds 1 --json >"$test_dir/output.json"
assert_json '.games[0].app_id=="730" and .games[0].samples[0].scanout==true and (.limitations|length>0)' <"$test_dir/output.json"
passed 'end-to-end JSON report without live game queries'

fixture_main 730 --seconds 1 >"$test_dir/output.txt"
grep -q '\[OK\] Tearing' "$test_dir/output.txt"
grep -q 'Still requires verification' "$test_dir/output.txt"
passed 'readable default report'

if fixture_main 999 --json >"$test_dir/error.json" 2>/dev/null; then exit 1; else status=$?; fi
[[ $status == 2 ]]
assert_json '.error|contains("No matching")' <"$test_dir/error.json"
passed 'no matching game is a structured operational error'

(
  report_file=$test_dir/process scope=game-process
  topology='[]'
  gamemode() {
    [[ $1 == QueryStatus ]]
    printf 'i 2'
  }
  run() {
    case "$1" in
      ps) printf '%s 0 TS 0\n' "$$" ;;
      ionice) printf 'none: prio 0' ;;
      *)
        printf 'Unexpected process probe: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  }
  selected=$(jq -cn --argjson pid "$$" --arg start "$(process_start "$$")" '{pid:$pid,process_start:$start}')
  process_report "$selected"
  jq -s -e 'any(.[];.data.check=="GameMode registration" and .data.status=="OK") and any(.[];.data.check=="Thread scheduling" and .data.detail.inspected_threads==1)' "$report_file" >/dev/null
)
passed 'process and thread reporting using a test-shell PID, not a game'

(
  report_file=$test_dir/system scope=system
  topology='[]'
  run() {
    case "$1" in
      uname) printf 'fixture-kernel' ;;
      busctl) printf 'u %s' "$$" ;;
      drm_info) printf '{"/dev/dri/card1":{"driver":{"name":"fixture","caps":{"ASYNC_PAGE_FLIP":1,"ATOMIC_ASYNC_PAGE_FLIP":1,"CURSOR_WIDTH":256,"CURSOR_HEIGHT":256}}}}' ;;
      nvidia-smi) printf 'fixture GPU' ;;
      journalctl | udevadm) return 1 ;;
      *)
        printf 'Unexpected system probe: %s\n' "$1" >&2
        exit 1
        ;;
    esac
  }
  gamemode() {
    [[ $1 == ListGames ]]
    printf 'a(io) 2 %s "/game/one" %s "/game/two"' "$$" "$$"
  }
  system_report
  jq -s -e 'any(.[];.data.check=="Registered GameMode clients" and (.data.detail|length)==2) and any(.[];.data.check=="DRM interpretation")' "$report_file" >/dev/null
)
passed 'system reporting and GameMode client parsing with mocked probes'

printf 'Passed %s Bash diagnostic tests.\n' "$tests"
