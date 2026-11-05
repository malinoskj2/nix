#!/usr/bin/env bash
# Adapted from https://serverfault.com/q/244944.

readonly scsi_disk='^\.\./devices(/.+)/host[0-9]+/target([0-9]+):([0-9]+):([0-9]+)/[0-9:]+/block/([^/]+)$'

shopt -s nullglob

for block in /sys/block/sd*; do
  [[ "$(readlink "$block")" =~ $scsi_disk ]] || continue
  path="/sys/devices${BASH_REMATCH[1]}"
  host="${BASH_REMATCH[2]}"
  channel="${BASH_REMATCH[3]}"
  target="${BASH_REMATCH[4]}"
  device="${BASH_REMATCH[5]}"

  if [[ "$path" =~ /usb[0-9]*/ ]]; then
    echo "(Device $device is not an ATA device, but a USB device [e. g. a pen drive])"
  else
    port_file="$path/host$host/scsi_host/host$host/unique_id"
    echo "$device: ata$(<"$port_file").$channel$target"
  fi
done
