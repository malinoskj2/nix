#!/usr/bin/env bash
# Join a Wi-Fi network interactively: scan, pick an SSID, enter its passphrase.
#
# The script must run as root. Nothing about the network is declared in Nix: the generated
# wpa_supplicant config lives under /run/wifi-connect, so a reboot forgets it.

readonly conf_dir=/run/wifi-connect
readonly log_file="$conf_dir/wpa_supplicant.log"

warn() {
  printf 'wifi-connect: %s\n' "$*" >&2
}

die() {
  warn "$@"
  exit 1
}

is_connected() {
  local interface="$1"

  iw dev "$interface" link 2>/dev/null | grep -q "Connected to"
}

(($(id -u) == 0)) || die "must run as root (try: sudo wifi-connect)"

ifaces=()
shopt -s nullglob
for wireless_dir in /sys/class/net/*/wireless; do
  ifaces+=("$(basename "$(dirname "$wireless_dir")")")
done
shopt -u nullglob
((${#ifaces[@]} > 0)) || die "no wireless interface found"

if ((${#ifaces[@]} == 1)); then
  iface="${ifaces[0]}"
else
  echo "Wireless interfaces:"
  select candidate in "${ifaces[@]}"; do
    [[ -n "$candidate" ]] && iface="$candidate" && break
  done
fi
echo "Using interface: $iface"

# A soft rfkill block makes the scan return nothing with no useful error.
if rfkill list | grep -q "Soft blocked: yes"; then
  echo "Unblocking rfkill..."
  rfkill unblock wifi
fi

ip link set "$iface" up
echo "Scanning..."

# Networks are listed strongest first, once per SSID, without hidden ones.
mapfile -t networks < <(
  iw dev "$iface" scan 2>/dev/null |
    awk '
      /^BSS/      { sig = ""; ssid = "" }
      /signal:/   { sig = $2 }
      /^\tSSID: / { ssid = substr($0, 8); if (ssid != "") print sig "\t" ssid }
    ' |
    sort -rn -k1,1 |
    awk -F'\t' '!seen[$2]++ { printf "%s (%s dBm)\n", $2, $1 }'
)
((${#networks[@]} > 0)) || die "no networks found; is the antenna blocked?"

echo
echo "Networks:"
select choice in "${networks[@]}"; do
  [[ -n "$choice" ]] && break
done
ssid="${choice% (*}"

printf 'Passphrase for %s (blank if open): ' "$ssid"
stty -echo
read -r passphrase || true
stty echo
echo

mkdir -p "$conf_dir"
chmod 700 "$conf_dir"
conf_file="$conf_dir/$iface.conf"

# wpa_passphrase reads stdin only from a terminal, so the passphrase goes in its arguments. It also
# echoes the passphrase back as a #psk comment; dropping that line leaves only the hash on disk.
if [[ -n "$passphrase" ]]; then
  wpa_passphrase "$ssid" "$passphrase" | grep -v $'^\t#psk=' >"$conf_file"
else
  printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$ssid" >"$conf_file"
fi
chmod 600 "$conf_file"

# A supplicant from an earlier run would keep driving the interface with its old network.
pkill -f "wpa_supplicant.*-i$iface" 2>/dev/null || true
sleep 1

echo "Associating..."
wpa_supplicant -B -i "$iface" -c "$conf_file" -f "$log_file" >/dev/null

# wpa_supplicant -B returns before association completes, so the script polls the link.
for _ in {1..30}; do
  is_connected "$iface" && break
  sleep 1
done

if ! is_connected "$iface"; then
  warn "failed to associate; last log lines:"
  tail -n 15 "$log_file" >&2 || true
  exit 1
fi

echo "Requesting DHCP lease..."
dhcpcd -n "$iface" >/dev/null 2>&1 || dhcpcd "$iface" >/dev/null 2>&1 || true

address=
for _ in {1..15}; do
  address="$(ip -4 -br addr show "$iface" | awk '{print $3}')" || true
  [[ -n "$address" ]] && break
  sleep 1
done

echo
if [[ -n "$address" ]]; then
  echo "Connected to $ssid"
  echo "  $iface: $address"
else
  echo "Associated with $ssid but no DHCP lease yet."
  echo "  check: ip addr show $iface"
fi
