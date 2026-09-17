#!/usr/bin/env bash

NETWORK="192.168.1.0/24"
UNKNOWN_MESSAGE="Unknown Service"
SERVICE="${1:-}"
PORT=

if [ "$SERVICE" = "plex" ]; then
	PORT=32400
elif [ "$SERVICE" = "qbittorrent" ]; then
	PORT=8080
fi

if [ -z "$PORT" ]; then
	echo "$UNKNOWN_MESSAGE"
else
	nmap --open -p "$PORT" "$NETWORK" | sed -n '/scan report/p' | awk '{print $5}'
fi
