probe_url() {
  local url=$1 timeout=$2 resp meta body extra=()
  [[ -n ${3:-} ]] && extra=(--resolve "$3")
  resp=$(
    curl "${extra[@]}" -ks -L --max-redirs 5 --connect-timeout "$timeout" --max-time "$((timeout * 2))" \
      --max-filesize 1048576 -H 'Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.5' \
      -o - -w '\037%{http_code}\t%{time_connect}\t%{content_type}' "$url" | tr -d '\000'
    exit "${PIPESTATUS[0]}"
  ) && probe_rc=0 || probe_rc=$?
  meta=${resp##*$'\037'}
  body=${resp%$'\037'*}
  [[ $resp == *$'\037'* ]] || {
    meta=$'000\t0\t'
    body=""
  }
  probe_code=${meta%%$'\t'*}
  meta=${meta#*$'\t'}
  probe_connected=1
  [[ ${meta%%$'\t'*} =~ ^0*\.?0*$ ]] && probe_connected=0
  probe_type=${meta#*$'\t'}
  probe_title=$(printf '%s' "${body:0:262144}" | tr '\r\n\t' '   ' | grep -oi '<title[^>]*>[^<]*' | head -n 1 |
    sed -e 's/<[^>]*>//' -e 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g' \
      -e 's/^ *//; s/ *$//; s/  */ /g' | head -c 120) || probe_title=""
  probe_hash=$(printf '%s' "$body" | sha256sum | cut -c 1-16)
  probe_https_hint=0
  if grep -qiE 'https (server|port)|plain http request' <<<"$body"; then probe_https_hint=1; fi
}

probe_ok() {
  printf '%s\tok\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$probe_code" "$probe_type" "$probe_title" "$probe_hash"
}

probe_port() {
  local addr=$1 port=$2 timeout=$3 host scheme
  host=$addr
  [[ $host == *:* && $host != \[* ]] && host="[$host]"
  for scheme in http https; do
    probe_url "$scheme://$host:$port/" "$timeout"
    if [[ $probe_code == 000 ]]; then
      if [[ $probe_connected == 0 ]] && ((probe_rc == 7 || probe_rc == 28)); then
        printf '%s\tunreachable\n' "$port"
        return
      fi
      continue
    fi
    if [[ $scheme == http && $probe_code == 400 && $probe_https_hint == 1 ]]; then
      continue
    fi
    probe_ok "$port" "$scheme://$host:$port/"
    return
  done
  printf '%s\tnone\n' "$port"
}

probe_all() {
  local timeout=$1 target pids=()
  shift
  for target in "$@"; do
    probe_port "${target%:*}" "${target##*:}" "$timeout" &
    pids+=($!)
  done
  ((${#pids[@]} == 0)) || wait "${pids[@]}"
}

probe_sites() {
  local timeout=$1 pids=()
  shift
  while (($#)); do
    (
      probe_url "$1" "$timeout" "$2"
      if [[ $probe_code == 000 ]]; then
        printf '%s\tnone\n' "$1"
      else
        probe_ok "$1" "$1"
      fi
    ) &
    pids+=($!)
    shift 2
  done
  ((${#pids[@]} == 0)) || wait "${pids[@]}"
}
