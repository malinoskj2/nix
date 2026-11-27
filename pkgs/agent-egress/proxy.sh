# shellcheck shell=bash
state=${STATE_DIRECTORY:?}
publish=${AGENT_BROKER_SOCKET_DIR:?}
conf=$state/mitmproxy
umask 077
mkdir -p "$conf"
if [[ ! -s $conf/mitmproxy-ca.pem ]]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$conf/ca.ec"
  openssl pkcs8 -topk8 -nocrypt -in "$conf/ca.ec" -out "$conf/ca.key"
  rm -f "$conf/ca.ec"
  openssl req -x509 -new -key "$conf/ca.key" -sha256 -days 3650 \
    -subj "/CN=agent-broker egress CA ($(uname -n))" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$conf/mitmproxy-ca-cert.pem"
  cat "$conf/mitmproxy-ca-cert.pem" "$conf/ca.key" >"$conf/mitmproxy-ca.pem.tmp"
  mv "$conf/mitmproxy-ca.pem.tmp" "$conf/mitmproxy-ca.pem"
  rm -f "$conf/ca.key"
fi
install -m 0644 "$conf/mitmproxy-ca-cert.pem" "$publish/ca.pem.tmp"
mv "$publish/ca.pem.tmp" "$publish/ca.pem"
exec mitmdump --quiet \
  --listen-host 127.0.0.1 --listen-port "${AGENT_EGRESS_PORT:-3128}" \
  --set confdir="$conf" \
  --set connection_strategy=eager \
  --set ssl_verify_upstream_trusted_ca="${AGENT_EGRESS_UPSTREAM_CA:?}" \
  --set termlog_verbosity=error \
  --scripts "$AGENT_EGRESS_ADDON"
