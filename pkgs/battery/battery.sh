#!/usr/bin/env bash
# Print the laptop battery's charge percentage and status, one per line.

readonly supply=/sys/class/power_supply/BAT0

cat "$supply/capacity"
cat "$supply/status"
