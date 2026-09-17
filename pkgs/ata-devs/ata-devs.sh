#!/usr/bin/env bash
# Map the ataN.NN port names in kernel ATA errors to their sd block devices.
#
# USB disks have no ATA port and are reported as such.
#
# Adapted from https://serverfault.com/q/244944.

shopt -s nullglob

for block in /sys/block/sd*; do
  readlink "$block" |
    sed 's^\.\./devices^/sys/devices^ ;
      s^/host[0-9]\{1,2\}/target^ ^ ;
      s^/[0-9]\{1,2\}\(:[0-9]\)\{3\}/block/^ ^' |
    while IFS=' ' read -r path scsi_target device; do
      IFS=: read -r host channel id <<<"$scsi_target"

      if [[ "$path" =~ /usb[0-9]*/ ]]; then
        echo "(Device $device is not an ATA device, but a USB device [e. g. a pen drive])"
      else
        port_file="$path/host$host/scsi_host/host$host/unique_id"
        echo "$device: ata$(<"$port_file").$channel$id"
      fi
    done
done
