#!/usr/bin/env bash
# Interactive wifi join. Nothing about the network lives in nix: this scans,
# prompts for an SSID and passphrase, and brings the link up imperatively.
#
# Needs root for scan/associate.

CONF_DIR="/run/wifi_connect"
LOG="$CONF_DIR/wpa_supplicant.log"

die() {
	echo "error: $*" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0)"

for t in iw wpa_supplicant wpa_passphrase dhcpcd; do
	command -v "$t" >/dev/null 2>&1 || die "missing '$t' - add it to the host's package.nix"
done

# Pick the wireless interface. Prompt only when there is more than one.
IFACES=()
for d in /sys/class/net/*/wireless; do
	[ -e "$d" ] && IFACES+=("$(basename "$(dirname "$d")")")
done
[ "${#IFACES[@]}" -gt 0 ] || die "no wireless interface found"

if [ "${#IFACES[@]}" -eq 1 ]; then
	IFACE="${IFACES[0]}"
else
	echo "Wireless interfaces:"
	select i in "${IFACES[@]}"; do
		[ -n "$i" ] && {
			IFACE="$i"
			break
		}
	done
fi
echo "Using interface: $IFACE"

# A soft rfkill block makes the scan return nothing with no useful error.
if command -v rfkill >/dev/null 2>&1 && rfkill list | grep -q "Soft blocked: yes"; then
	echo "Unblocking rfkill..."
	rfkill unblock wifi
fi

ip link set "$IFACE" up
echo "Scanning..."

# Sort by signal strength, strongest first, and drop hidden/empty SSIDs.
mapfile -t SSIDS < <(
	iw dev "$IFACE" scan 2>/dev/null |
		awk '
        /^BSS/          { sig=""; ssid="" }
        /signal:/       { sig=$2 }
        /^\tSSID: /     { ssid=substr($0, 8); if (ssid != "") print sig "\t" ssid }
      ' |
		sort -rn -k1,1 | awk -F'\t' '!seen[$2]++ { printf "%s (%s dBm)\n", $2, $1 }'
)
[ "${#SSIDS[@]}" -gt 0 ] || die "no networks found - is the antenna blocked?"

echo
echo "Networks:"
select choice in "${SSIDS[@]}"; do
	[ -n "$choice" ] && break
done
SSID="${choice% (*}"

printf 'Passphrase for %s (blank if open): ' "$SSID"
stty -echo
read -r PSK || true
stty echo
echo

mkdir -p "$CONF_DIR"
chmod 700 "$CONF_DIR"
CONF="$CONF_DIR/$IFACE.conf"

# wpa_passphrase writes the PSK hash, so the plaintext never hits disk.
if [ -n "$PSK" ]; then
	wpa_passphrase "$SSID" "$PSK" >"$CONF"
else
	cat >"$CONF" <<EOF
network={
	ssid="$SSID"
	key_mgmt=NONE
}
EOF
fi
chmod 600 "$CONF"

# Replace any supplicant we started earlier for this interface.
pkill -f "wpa_supplicant.*-i$IFACE" 2>/dev/null || true
sleep 1

echo "Associating..."
wpa_supplicant -B -i "$IFACE" -c "$CONF" -f "$LOG" >/dev/null

# Associated != authenticated; poll until wpa_state reports COMPLETED.
for _ in $(seq 1 30); do
	if iw dev "$IFACE" link 2>/dev/null | grep -q "Connected to"; then break; fi
	sleep 1
done

if ! iw dev "$IFACE" link 2>/dev/null | grep -q "Connected to"; then
	echo "failed to associate - last log lines:" >&2
	tail -n 15 "$LOG" >&2 || true
	exit 1
fi

echo "Requesting DHCP lease..."
dhcpcd -n "$IFACE" >/dev/null 2>&1 || dhcpcd "$IFACE" >/dev/null 2>&1 || true

for _ in $(seq 1 15); do
	ADDR=$(ip -4 -br addr show "$IFACE" | awk '{print $3}') || true
	[ -n "${ADDR:-}" ] && break
	sleep 1
done

echo
if [ -n "${ADDR:-}" ]; then
	echo "Connected to $SSID"
	echo "  $IFACE: $ADDR"
else
	echo "Associated with $SSID but no DHCP lease yet."
	echo "  check: ip addr show $IFACE"
fi
