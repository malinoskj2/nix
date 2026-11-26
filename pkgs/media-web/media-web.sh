usage() {
  cat <<'USAGE'
Usage: media-web [options]

Find the web UIs running on the media host and open the chosen ones in Firefox.

Options:
  -H, --host HOST    SSH host to inspect (default: $MEDIA_WEB_HOST or media)
  -l, --list         Print the web UIs instead of opening a picker
  -j, --json         Print the web UIs as JSON
  -a, --api          Also include ports that answer with JSON
  -t, --timeout SEC  Per-request connect timeout (default: 2)
  -d, --debug        Report discovery records and every probe on stderr
  -h, --help         Show this help

Ports that answer only through SSH (loopback or firewalled) open through an
SSH tunnel to a local port.
USAGE
}

host=${MEDIA_WEB_HOST:-media}
mode=pick
api=0
timeout=2

while (($#)); do
  case $1 in
    -H | --host)
      host=${2:?--host needs a value}
      shift
      ;;
    -l | --list) mode=list ;;
    -j | --json) mode=json ;;
    -a | --api) api=1 ;;
    -d | --debug) export MEDIA_WEB_DEBUG=1 ;;
    -t | --timeout)
      timeout=${2:?--timeout needs a value}
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

[[ $timeout =~ ^[1-9][0-9]*$ ]] || {
  echo "media-web: --timeout must be a whole number of seconds" >&2
  exit 2
}

# shellcheck source=/dev/null
source "$MEDIA_WEB_PROBE"

ssh_opts=(-T -o RequestTTY=no -o LogLevel=ERROR)
lan_addr=$(ssh "${ssh_opts[@]}" -G "$host" | awk '$1 == "hostname" { print $2; exit }')

discovery_status=0
discovery=$(ssh "${ssh_opts[@]}" "$host" bash -s <"$MEDIA_WEB_DISCOVER") || discovery_status=$?
if [[ -z $discovery ]]; then
  echo "media-web: discovery over ssh to $host failed" >&2
  exit 1
elif ((discovery_status)); then
  echo "media-web: discovery on $host exited with $discovery_status; using what it found" >&2
fi

debug() {
  if [[ -n ${MEDIA_WEB_DEBUG:-} ]]; then printf 'media-web: %s\n' "$*" >&2; fi
}
debug "discovery exit=$discovery_status records: $(cut -f 1 <<<"$discovery" | sort | uniq -c | tr -s ' \n' ' ')"

candidates=$(jq -nR '
  [inputs | split("\t")] as $rows
  | ($rows | map(select(.[0] == "U") | {(.[1]): .[2]}) | add // {}) as $units
  | $rows
  | map(select(.[0] == "L" or .[0] == "C") | .[1] |= tonumber)
  | group_by(.[1])
  | map({
      port: .[0][1],
      addrs: (map(.[2]) | unique),
      containers: (map(select(.[0] == "C") | .[3]) | unique),
      units: (map(select(.[0] == "L") | $units[.[4]] // empty) | unique),
      processes: (map(select(.[0] == "L" and .[3] != "") | .[3]) | unique)
    })
  | map(
      . + {
        label: ((.containers + .units + .processes)[0] // "port \(.port)"),
        lan: any(.addrs[]; test("^(127\\.|\\[::1\\]$|::1$)") | not),
        target: (
          [.addrs[] | select(test("^(\\*|0\\.0\\.0\\.0|\\[::\\])$") | not)][0]
          | if . == null or test("^(127\\.|\\[::1\\]$|::1$)") then "127.0.0.1" else ltrimstr("[") | rtrimstr("]") end
        )
      }
    )
' <<<"$discovery")

sites=$(jq -nR '
  [inputs | split("\t") | select(.[0] == "P") | .[1] as $proxy
    | (.[2] | fromjson? // empty) | (.apps.http.servers // {})[]
    | ((.listen // []) | map(sub(".*:"; "") | tonumber? // empty)) as $ports
    | (.routes // [])[] as $route
    | ([$route.handle // [] | .. | objects | select(.handler? == "reverse_proxy") | .upstreams[]?.dial] | unique | join(",")) as $upstream
    | ($route.match // [])[] as $m
    | ($m.host // [])[] as $h | select($h | test("\\*") | not)
    | (($m.path // ["/"])[] | rtrimstr("*") | if startswith("/") then . else "/" + . end) as $path
    | $ports[] as $port
    | (if $port == 443 then "https" else "http" end) as $scheme
    | {proxy: $proxy, host: $h, path: $path, port: $port, upstream: $upstream,
       url: "\($scheme)://\($h)\(if ($scheme == "http" and $port == 80) or ($scheme == "https" and $port == 443) then "" else ":\($port)" end)\($path)",
       label: "\($h)\(if $path == "/" then "" else $path end)"}]
  | unique_by(.url)
' <<<"$discovery")

debug "candidates=$(jq length <<<"$candidates") sites=$(jq length <<<"$sites") lan_addr=$lan_addr"

mapfile -t lan_ports < <(jq -r --arg a "$lan_addr" '.[] | select(.lan) | "\($a):\(.port)"' <<<"$candidates")
direct=$(probe_all "$timeout" "${lan_ports[@]}")

mapfile -t remote_targets < <(
  jq -r --rawfile d <(printf '%s\n' "$direct") '
    ($d | split("\n") | map(split("\t") | select(.[1] == "unreachable") | .[0] | tonumber)) as $miss
    | .[] | select((.lan | not) or (.port as $p | $miss | index($p))) | "\(.target):\(.port)"
  ' <<<"$candidates"
)
tunneled=""
if ((${#remote_targets[@]})); then
  tunneled=$({
    if [[ -n ${MEDIA_WEB_DEBUG:-} ]]; then echo 'MEDIA_WEB_DEBUG=1'; fi
    cat "$MEDIA_WEB_PROBE"
    printf 'probe_all %q' "$timeout"
    printf ' %q' "${remote_targets[@]}"
    printf '\n'
  } | ssh "${ssh_opts[@]}" "$host" bash -s) || echo "media-web: probing through ssh failed" >&2
fi

site_args=()
if [[ $lan_addr =~ ^[0-9.]+$|: ]]; then
  mapfile -t site_args < <(jq -r --arg a "$lan_addr" '.[] | .url, "\(.host):\(.port):\($a)"' <<<"$sites")
else
  mapfile -t site_args < <(jq -r '.[] | .url, ""' <<<"$sites")
fi
site_probes=$(probe_sites "$timeout" "${site_args[@]}")

site_results=$(jq -nR --argjson s "$sites" --argjson api "$api" '
  [inputs | split("\t") | select(.[1] == "ok")
    | {url: .[2], via: "direct", status: (.[3] | tonumber), content_type: .[4], title: .[5], hash: .[6]}
    | . as $r | ($s[] | select(.url == $r.url)) as $k
    | $r + {port: $k.port, label: $k.label, upstream: $k.upstream, host: $k.host, path: $k.path, containers: [$k.proxy], units: [], processes: []}]
  | map(select(
      (.content_type | test("text/html|application/xhtml"; "i"))
      or ($api == 1 and (.content_type | test("json"; "i")))
    ))
' <<<"$site_probes")

empty_hash=$(printf '' | sha256sum | cut -c 1-16)
results=$(jq -nR --argjson c "$candidates" --argjson api "$api" --argjson sites "$site_results" --arg empty "$empty_hash" --arg lan "$lan_addr" '
  [inputs | split("\t") | select(.[1] == "ok")
    | {port: (.[0] | tonumber), via: .[7], url: .[2], status: (.[3] | tonumber), content_type: .[4], title: .[5], hash: .[6], upstream: ""}]
  | map(select(
      (.content_type | test("text/html|application/xhtml"; "i"))
      or ($api == 1 and (.content_type | test("json"; "i")))
    ))
  | group_by(.port) | map(sort_by(.via) | .[0])
  | map(. as $r | ($c[] | select(.port == $r.port)) as $k
      | $r + {label: $k.label, containers: $k.containers, units: $k.units, processes: $k.processes})
  | . + $sites
  | group_by(
      if .hash == $empty then ["url", .url]
      elif (.upstream // "") != "" then ["upstream", .port, .status, .hash, .upstream]
      elif .host == null or (.host == $lan and .path == "/") then ["listener", .port, .status, .hash]
      else ["url", .url]
      end
    )
  | map(
      sort_by([(.url | test("^[a-z]+://([0-9.]+|\\[[^]]*\\])(:|/|$)")), (.url | length)])
      | .[0] + {aliases: (.[1:] | map({label, url}))}
      | del(.hash, .host, .path)
    )
  | sort_by(.label, .port)
' < <(
  if [[ -n $direct ]]; then awk '{ print $0 "\tdirect" }' <<<"$direct"; fi
  if [[ -n $tunneled ]]; then awk '{ print $0 "\tssh" }' <<<"$tunneled"; fi
))

debug "direct=$(grep -c $'\tok\t' <<<"$direct" || true) ssh=$(grep -c $'\tok\t' <<<"$tunneled" || true) sites=$(grep -c $'\tok\t' <<<"$site_probes" || true) kept=$(jq length <<<"$results")"

if [[ $mode == json ]]; then
  printf '%s\n' "$results"
  exit 0
fi

rows=$(jq -r '.[] | [.label, (.port | tostring), (if .title == "" then "-" else .title end), (if .via == "ssh" then "\(.url) (ssh)" else .url end)] | @tsv' <<<"$results")

if [[ -z $rows ]]; then
  echo "media-web: no web UIs found on $host" >&2
  exit 1
fi

if [[ $mode == list ]]; then
  awk -F '\t' '
    { for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } }
    END { for (r = 1; r <= NR; r++) printf "%-*s  %-*s  %-*s  %s\n", w[1], cell[r, 1], w[2], cell[r, 2], w[3], cell[r, 3], cell[r, 4] }
  ' <<<"$rows"
  exit 0
fi

open_url() {
  if command -v firefox >/dev/null 2>&1; then
    firefox --new-tab "$1" >/dev/null 2>&1 &
  else
    xdg-open "$1" >/dev/null 2>&1 &
  fi
}

port_free() {
  ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

open_tunnel() {
  local target=$1 port=$2 scheme=$3 local_port
  local_port=$port
  until port_free "$local_port"; do
    local_port=$((RANDOM % 20000 + 40000))
  done
  ssh "${ssh_opts[@]}" -f -N -o ExitOnForwardFailure=yes -L "127.0.0.1:$local_port:$target:$port" "$host" || return 1
  echo "media-web: tunnel localhost:$local_port -> $host $target:$port (stop with: pkill -f 'L 127.0.0.1:$local_port:')" >&2
  open_url "$scheme://localhost:$local_port/"
}

selection=$(fzf --multi --delimiter '\t' --with-nth 1,2,3,4 --tabstop 4 \
  --header 'label  port  title  url (tab: select several)' <<<"$rows") || exit 0

while IFS=$'\t' read -r _ port _ shown; do
  url=${shown% (ssh)}
  if [[ $shown == *" (ssh)" ]]; then
    target=$(jq -r --argjson p "$port" '.[] | select(.port == $p) | .target' <<<"$candidates")
    open_tunnel "$target" "$port" "${url%%:*}"
  else
    open_url "$url"
  fi
done <<<"$selection"
