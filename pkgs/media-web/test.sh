#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fakes=$work/bin
mkdir -p "$fakes"

cat >"$fakes/ssh" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" -G "* ]]; then echo "hostname 10.0.0.1"; exit 0; fi
while [[ $1 == -* ]]; do
  case $1 in -o | -L) shift 2 ;; *) shift ;; esac
done
shift
exec "$@"
STUB

cat >"$fakes/ss" <<'STUB'
#!/usr/bin/env bash
printf 'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*\n'
STUB

cat >"$fakes/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 ${3:-}" in
  "ps {{.Names}}	{{.Ports}}") printf 'proxy\t0.0.0.0:80->80/tcp\n' ;;
  "ps {{.Names}}	{{.Image}}") printf 'proxy\tcaddy:2\n' ;;
  exec*)
    [[ $FAKE_EXEC == hang ]] && exec sleep 60
    rp() { printf '{"handler":"reverse_proxy","upstreams":[{"dial":"%s"}]}' "$1"; }
    printf '{"apps":{"http":{"servers":{"srv0":{"listen":[":80"],"routes":['
    printf '{"match":[{"host":["10.0.0.1"]}],"handle":[{"handler":"file_server"}]},'
    printf '{"match":[{"host":["home.test"]}],"handle":[{"handler":"file_server"}]},'
    printf '{"match":[{"host":["c.test"]}],"handle":[{"handler":"file_server"}]},'
    printf '{"match":[{"host":["d.test"]}],"handle":[{"handler":"file_server"}]},'
    printf '{"match":[{"host":["e.test"]}],"handle":[%s]},' "$(rp app-e:80)"
    printf '{"match":[{"host":["f.test"]}],"handle":[%s]},' "$(rp app-e:80)"
    printf '{"match":[{"host":["a.test"]}],"handle":[%s]},' "$(rp app-a:80)"
    printf '{"match":[{"host":["b.test"]}],"handle":[{"handler":"subroute","routes":[{"handle":[%s]}]}]},' "$(rp app-b:80)"
    printf '{"match":[{"host":["*.wild.test"]}]}'
    printf ']}}}}}\n'
    ;;
esac
STUB

cat >"$fakes/caddy" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

cat >"$fakes/curl" <<'STUB'
#!/usr/bin/env bash
url=${!#}
resolve=""
format=""
while (($#)); do
  case $1 in
    --resolve) resolve=$2 ;;
    -w) format=$2 ;;
  esac
  shift
done
format=${format//\\t/$'\t'}
format=${format//\\n/$'\n'}
reply() {
  local w=${format//'%{http_code}'/$1}
  w=${w//'%{time_connect}'/$([[ $1 == 000 ]] && echo 0.000000 || echo 0.001)}
  printf '%s%s' "$2" "${w//'%{content_type}'/$3}"
}
case "$url|$resolve" in
  "http://10.0.0.1:80/|" | "http://10.0.0.1/|10.0.0.1:80:10.0.0.1" | "http://home.test/|home.test:80:10.0.0.1")
    reply 200 '<html><title>Home</title>static</html>' 'text/html' ;;
  "http://c.test/|c.test:80:10.0.0.1" | "http://d.test/|d.test:80:10.0.0.1")
    reply 200 '<html><title>SPA</title>bundle</html>' 'text/html' ;;
  "http://e.test/|e.test:80:10.0.0.1" | "http://f.test/|f.test:80:10.0.0.1")
    reply 200 '<html><title>App E</title>e</html>' 'text/html' ;;
  "http://a.test/|a.test:80:10.0.0.1") reply 200 '<html><title>Login</title>app a</html>' 'text/html' ;;
  "http://b.test/|b.test:80:10.0.0.1") reply 200 '<html><title>Login</title>app b</html>' 'text/html' ;;
  *)
    reply 000 "" ""
    exit 7
    ;;
esac
STUB
sed -i "1s|.*|#!$BASH|" "$fakes"/*
chmod +x "$fakes"/*

export PATH="$fakes:$PATH" MEDIA_WEB_DISCOVER="$here/discover.sh" MEDIA_WEB_PROBE="$here/probe.sh"
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

FAKE_EXEC=ok bash "$MEDIA_WEB_DISCOVER" >"$work/discovery" 2>"$work/err" || fail "discovery exits nonzero without the host Caddy admin API"
grep -q '^L	80	' "$work/discovery" || fail "discovery lost the listener"
grep -q '^P	proxy	' "$work/discovery" || fail "discovery lost the container Caddy config"

start=$SECONDS
FAKE_EXEC=hang bash "$MEDIA_WEB_DISCOVER" >"$work/discovery" 2>"$work/err" || fail "a hung Caddy query fails discovery"
((SECONDS - start < 20)) || fail "a hung Caddy query was not bounded"
grep -q 'timed out' "$work/err" || fail "no note for the timed-out Caddy query"
grep -q '^C	80	' "$work/discovery" || fail "a hung Caddy query lost the container records"

FAKE_EXEC=ok bash "$here/media-web.sh" --json >"$work/out.json" 2>"$work/err" || fail "media-web --json: $(cat "$work/err")"
urls() { jq -c "$1" "$work/out.json"; }
jq -e 'length == 7' "$work/out.json" >/dev/null || fail "expected 7 entries: $(urls 'map(.url)')"
jq -e 'map(select(.title == "Login")) | length == 2' "$work/out.json" >/dev/null || fail "distinct Login sites were merged"
jq -e 'map(select(.title == "SPA")) | length == 2' "$work/out.json" >/dev/null || fail "identical static sites without an upstream were merged"
jq -e 'map(select(.title == "Home")) | length == 2' "$work/out.json" >/dev/null || fail "home.test should stay apart from the proxy's own port"
jq -e 'map(select(.title == "Home") | [.url, .aliases[].url] | sort) | any(. == ["http://10.0.0.1/", "http://10.0.0.1:80/"])' "$work/out.json" >/dev/null ||
  fail "the proxy's own port wasn't merged with its IP site: $(urls 'map(select(.title == "Home") | {url, aliases})')"
jq -e 'map(select(.title == "App E")) | length == 1 and (.[0].aliases | length == 1)' "$work/out.json" >/dev/null ||
  fail "sites on the same upstream weren't merged"

echo "media-web tests passed"
