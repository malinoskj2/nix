#!/usr/bin/env bash

cpu=$(awk -F ': ' '/^model name/ { print $2; exit }' /proc/cpuinfo)
cpu=$(sed -E 's/\((R|TM)\)//g; s/ [0-9]+-Core Processor$//; s/ (CPU )?@ .*$//; s/ Processor$//; s/ +/ /g' <<<"$cpu")

# nvidia-smi comes from PATH so it always matches the loaded driver.
gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 || true)
if [[ -z $gpu ]]; then
  gpu=$(lspci -mm -d ::0300 2>/dev/null | head -n 1 | awk -F '"' '{
    vendor = $4; device = $6
    sub(/ Corporation$/, "", vendor)
    if (match(device, /\[[^]]+\]/)) device = substr(device, RSTART + 1, RLENGTH - 2)
    print vendor " " device
  }' || true)
fi

# MemTotal leaves out what firmware and the kernel reserve; the online memory blocks add up to the
# installed size.
blocks=(/sys/devices/system/memory/memory*)
if [[ -r /sys/devices/system/memory/block_size_bytes && -e ${blocks[0]} ]]; then
  block=$((16#$(cat /sys/devices/system/memory/block_size_bytes)))
  online=$(cat /sys/devices/system/memory/memory*/state | grep -cx online || true)
  bytes=$((online * block))
else
  bytes=$(($(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) * 1024))
fi
gib=$((1024 * 1024 * 1024))
memory="$(((bytes + gib - 1) / gib)) GB"

root=$(findmnt --noheadings --output SOURCE --target / 2>/dev/null || true)
# A bind mount's source ends in the bound path, e.g. /dev/nvme0n1p2[/nix/store].
root=${root%%\[*}
disk=$(lsblk --nodeps --noheadings --output LABEL "$root" 2>/dev/null | head -n 1 || true)
if [[ -z $disk ]]; then
  parent=$(lsblk --nodeps --noheadings --output PKNAME "$root" 2>/dev/null | head -n 1 || true)
  if [[ -n $parent ]]; then
    disk=$(lsblk --nodeps --noheadings --output MODEL "/dev/$parent" 2>/dev/null | head -n 1 || true)
  fi
fi
disk=$(sed -E 's/^ +| +$//g' <<<"${disk:-$root}")

jq --null-input --compact-output \
  --arg cpu "$cpu" --arg gpu "$gpu" --arg memory "$memory" --arg disk "$disk" \
  '{ cpu: $cpu, gpu: $gpu, memory: $memory, disk: $disk }'
