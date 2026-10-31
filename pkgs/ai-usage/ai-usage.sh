#!/usr/bin/env bash

readonly claude_auth_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
readonly codex_auth_file="${CODEX_HOME:-$HOME/.codex}/auth.json"

format_duration() {
  local total_seconds="$1"
  local days hours minutes

  ((total_seconds >= 0)) || total_seconds=0

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

format_window_label() {
  local window_seconds="$1"

  case "$window_seconds" in
    18000) printf '5-hour' ;;
    86400) printf 'daily' ;;
    604800) printf 'weekly' ;;
    *)
      if ((window_seconds % 86400 == 0)); then
        printf '%d-day' "$((window_seconds / 86400))"
      elif ((window_seconds % 3600 == 0)); then
        printf '%d-hour' "$((window_seconds / 3600))"
      else
        printf '%ds' "$window_seconds"
      fi
      ;;
  esac
}

print_window() {
  local window_seconds="$1"
  local used="$2"
  local reset_epoch="$3"
  local remaining reset

  remaining="$(jq -nr --arg used "$used" '100 - ($used | tonumber)')"

  if [[ -z "$reset_epoch" ]]; then
    reset='not started'
  else
    reset="resets $(date -d "@$reset_epoch" '+%I:%M %p %Z')"
    reset+=" (in $(format_duration "$((reset_epoch - EPOCHSECONDS))"))"
  fi

  printf '  %-8s %5g%% used  %5g%% left  %s\n' \
    "$(format_window_label "$window_seconds")" "$used" "$remaining" "$reset"
}

unavailable() {
  printf '  unavailable: %s\n' "$1"
}

fetch_usage() {
  local url="$1"
  shift

  curl --disable --location --silent --show-error --fail-with-body \
    --connect-timeout 10 --max-time 30 \
    "$url" \
    -H 'Accept: application/json' \
    "$@"
}

show_claude_usage() {
  local access_token expires_at expired response error_message windows
  local window_seconds used reset_iso reset_epoch

  printf 'Claude\n'

  if [[ ! -r "$claude_auth_file" ]]; then
    unavailable "$claude_auth_file not found; run 'claude' and sign in"
    return 1
  fi

  if ! access_token="$(jq -er '.claudeAiOauth.accessToken' "$claude_auth_file")"; then
    unavailable "OAuth token missing; run 'claude' and sign in"
    return 1
  fi

  # Claude Code only refreshes the token while it runs.
  if expires_at="$(jq -er '.claudeAiOauth.expiresAt / 1000 | floor' "$claude_auth_file")" &&
    ((expires_at <= EPOCHSECONDS)); then
    expired="$(date -d "@$expires_at" '+%Y-%m-%d %I:%M %p %Z')"
    unavailable "OAuth token expired $expired; run 'claude' to refresh it"
    return 1
  fi

  if ! response="$(
    fetch_usage 'https://api.anthropic.com/api/oauth/usage' \
      -H 'anthropic-beta: oauth-2025-04-20' \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "$access_token")
  )"; then
    error_message="$(jq -r '.error.message // empty' <<<"$response" 2>/dev/null)"
    unavailable "usage request failed${error_message:+ ($error_message)}; run 'claude' to refresh login"
    return 1
  fi

  # A window the plan lacks is null, and resets_at is null for a window with no usage yet.
  if ! windows="$(
    jq -er '
      [[18000, .five_hour], [604800, .seven_day]]
      | map(select(.[1] != null))
      | map([.[0], .[1].utilization, .[1].resets_at])
      | if length == 0 or any(.[]; (.[1] | type) != "number") then
          error("invalid usage windows")
        else
          .[] | @tsv
        end
    ' <<<"$response"
  )"; then
    unavailable 'Anthropic returned an unexpected response'
    return 1
  fi

  while IFS=$'\t' read -r window_seconds used reset_iso; do
    reset_epoch=
    if [[ -n "$reset_iso" ]]; then
      reset_epoch="$(date -d "$reset_iso" +%s)"
    fi
    print_window "$window_seconds" "$used" "$reset_epoch"
  done <<<"$windows"
}

show_codex_usage() {
  local access_token account_id response windows
  local window_seconds used reset_epoch

  printf 'Codex\n'

  if [[ ! -r "$codex_auth_file" ]]; then
    unavailable "$codex_auth_file not found; run 'codex login'"
    return 1
  fi

  if ! access_token="$(jq -er '.tokens.access_token' "$codex_auth_file")" ||
    ! account_id="$(jq -er '.tokens.account_id' "$codex_auth_file")"; then
    unavailable "OAuth credentials missing; run 'codex login'"
    return 1
  fi

  if ! response="$(
    fetch_usage 'https://chatgpt.com/backend-api/wham/usage' \
      --config <(
        printf 'header = "Authorization: Bearer %s"\n' "$access_token"
        printf 'header = "ChatGPT-Account-Id: %s"\n' "$account_id"
      )
  )"; then
    unavailable "usage request failed; run 'codex login' to refresh login"
    return 1
  fi

  if ! windows="$(
    jq -er '
      [[18000, .rate_limit.primary_window], [604800, .rate_limit.secondary_window]]
      | map(select(.[1] != null))
      | map([.[1].limit_window_seconds // .[0], .[1].used_percent, .[1].reset_at])
      | if length == 0 or any(.[][]; type != "number") then
          error("invalid rate-limit windows")
        else
          .[] | @tsv
        end
    ' <<<"$response"
  )"; then
    unavailable 'OpenAI returned an unexpected response'
    return 1
  fi

  while IFS=$'\t' read -r window_seconds used reset_epoch; do
    print_window "$window_seconds" "$used" "$reset_epoch"
  done <<<"$windows"
}

status=0
show_claude_usage || status=1
printf '\n'
show_codex_usage || status=1
exit "$status"
