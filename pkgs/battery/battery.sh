#!/usr/bin/env bash

readonly supply=/sys/class/power_supply/BAT0

cat "$supply/capacity"
cat "$supply/status"
