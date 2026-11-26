probe_url() {
  local url=$1 timeout=$2 body meta
  body=$(mktemp)
  meta=$(curl -ks -L --max-redirs 5 --connect-timeout "$timeout" --max-time "$((timeout * 2))" \
    -H 'Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.5' \
    -o "$body" -w '%{http_code}\t%{time_connect}\t%{content_type}' "$url") && probe_rc=0 || probe_rc=$?
  probe_code=${meta%%$'\t'*}
  meta=${meta#*$'\t'}
  probe_connected=1
  [[ ${meta%%$'\t'*} =~ ^0*\.?0*$ ]] && probe_connected=0
  probe_type=${meta#*$'\t'}
  probe_title=$(head -c 262144 "$body" | tr '\r\n\t' '   ' | grep -oi '<title[^>]*>[^<]*' | head -n 1 |
    sed -e 's/<[^>]*>//' -e 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g' \
      -e 's/^ *//; s/ *$//; s/  */ /g' | head -c 120) || probe_title=""
  probe_https_hint=0
  grep -qiE 'https (server|port)|plain http request' "$body" 2>/dev/null && probe_https_hint=1
  rm -f "$body"
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
    printf '%s\tok\t%s\t%s\t%s\t%s\n' "$port" "$scheme://$host:$port/" "$probe_code" "$probe_type" "$probe_title"
    return
  done
  printf '%s\tnone\n' "$port"
}

probe_all() {
  local timeout=$1 dir target pids=()
  shift
  dir=$(mktemp -d)
  for target in "$@"; do
    probe_port "${target%:*}" "${target##*:}" "$timeout" >"$dir/${target##*:}" &
    pids+=($!)
  done
  ((${#pids[@]} == 0)) || wait "${pids[@]}"
  cat "$dir"/* 2>/dev/null || true
  rm -rf "$dir"
}
