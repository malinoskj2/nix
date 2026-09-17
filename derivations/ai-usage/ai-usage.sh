#!/usr/bin/env bash

set -uo pipefail

readonly claude_auth_file="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/.credentials.json"
readonly codex_auth_file="${CODEX_HOME:-${HOME}/.codex}/auth.json"

for dependency in curl jq date; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'error: required command not found: %s\n' "$dependency" >&2
    exit 1
  fi
done

format_duration() {
  local total_seconds="$1"
  local days hours minutes

  if ((total_seconds < 0)); then
    total_seconds=0
  fi

  days=$((total_seconds / 86400))
  hours=$(((total_seconds % 86400) / 3600))
  minutes=$(((total_seconds % 3600) / 60))

  if ((days > 0)); then
    printf '%dd %dh %dm' "$days" "$hours" "$minutes"
  elif ((hours > 0)); then
    printf '%dh %dm' "$hours" "$minutes"
  else
    printf '%dm' "$minutes"
  fi
}

print_window() {
  local label="$1"
  local used="$2"
  local reset_epoch="$3"
  local remaining reset_local reset_in now

  remaining="$(jq -nr --arg used "$used" '100 - ($used | tonumber)')"
  reset_local="$(date -d "@$reset_epoch" '+%I:%M %p %Z')"
  now="$(date +%s)"
  reset_in="$(format_duration "$((reset_epoch - now))")"

  printf '  %-8s %5g%% used  %5g%% left  resets %s (in %s)\n' \
    "$label" "$used" "$remaining" "$reset_local" "$reset_in"
}

show_claude_usage() {
  local access_token response five_hour_used five_hour_reset five_hour_reset_iso
  local seven_day_used seven_day_reset seven_day_reset_iso

  printf 'Claude\n'

  if [[ ! -r "$claude_auth_file" ]]; then
    printf "  unavailable: %s not found; run 'claude' and sign in\n" "$claude_auth_file"
    return 1
  fi

  if ! access_token="$(jq -er '.claudeAiOauth.accessToken' "$claude_auth_file")"; then
    printf "  unavailable: OAuth token missing; run 'claude' and sign in\n"
    return 1
  fi

  if ! response="$(
    curl -q -L --silent --show-error --fail-with-body \
      --connect-timeout 10 --max-time 30 \
      'https://api.anthropic.com/api/oauth/usage' \
      -H 'anthropic-beta: oauth-2025-04-20' \
      -H 'Accept: application/json' \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "$access_token")
  )"; then
    printf '  unavailable: usage request failed; open Claude Code to refresh login\n'
    return 1
  fi

  if ! five_hour_used="$(jq -er '.five_hour.utilization' <<<"$response")" ||
    ! five_hour_reset_iso="$(jq -er '.five_hour.resets_at' <<<"$response")" ||
    ! five_hour_reset="$(date -d "$five_hour_reset_iso" +%s)" ||
    ! seven_day_used="$(jq -er '.seven_day.utilization' <<<"$response")" ||
    ! seven_day_reset_iso="$(jq -er '.seven_day.resets_at' <<<"$response")" ||
    ! seven_day_reset="$(date -d "$seven_day_reset_iso" +%s)"; then
    printf '  unavailable: Anthropic returned an unexpected response\n'
    return 1
  fi

  print_window '5-hour' "$five_hour_used" "$five_hour_reset"
  print_window 'weekly' "$seven_day_used" "$seven_day_reset"
}

show_codex_usage() {
  local access_token account_id response five_hour_used five_hour_reset
  local seven_day_used seven_day_reset

  printf 'Codex\n'

  if [[ ! -r "$codex_auth_file" ]]; then
    printf "  unavailable: %s not found; run 'codex login'\n" "$codex_auth_file"
    return 1
  fi

  if ! access_token="$(jq -er '.tokens.access_token' "$codex_auth_file")" ||
    ! account_id="$(jq -er '.tokens.account_id' "$codex_auth_file")"; then
    printf "  unavailable: OAuth credentials missing; run 'codex login'\n"
    return 1
  fi

  if ! response="$(
    curl -q -L --silent --show-error --fail-with-body \
      --connect-timeout 10 --max-time 30 \
      'https://chatgpt.com/backend-api/wham/usage' \
      -H 'Accept: application/json' \
      --config <(
        printf 'header = "Authorization: Bearer %s"\n' "$access_token"
        printf 'header = "ChatGPT-Account-Id: %s"\n' "$account_id"
      )
  )"; then
    printf "  unavailable: usage request failed; run 'codex login' to refresh login\n"
    return 1
  fi

  if ! five_hour_used="$(jq -er '.rate_limit.primary_window.used_percent' <<<"$response")" ||
    ! five_hour_reset="$(jq -er '.rate_limit.primary_window.reset_at' <<<"$response")" ||
    ! seven_day_used="$(jq -er '.rate_limit.secondary_window.used_percent' <<<"$response")" ||
    ! seven_day_reset="$(jq -er '.rate_limit.secondary_window.reset_at' <<<"$response")"; then
    printf '  unavailable: OpenAI returned an unexpected response\n'
    return 1
  fi

  print_window '5-hour' "$five_hour_used" "$five_hour_reset"
  print_window 'weekly' "$seven_day_used" "$seven_day_reset"
}

status=0
show_claude_usage || status=1
printf '\n'
show_codex_usage || status=1
exit "$status"
