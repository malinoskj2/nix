#!/usr/bin/env bash

readonly battery=/sys/class/power_supply/BAT0

cat "$battery/capacity"
cat "$battery/status"
