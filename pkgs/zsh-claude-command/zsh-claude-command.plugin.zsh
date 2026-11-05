typeset -g ZSH_CLAUDE_COMMAND_MODEL="${ZSH_CLAUDE_COMMAND_MODEL:-}"
typeset -g ZSH_CLAUDE_COMMAND_PROMPT_EXTEND="${ZSH_CLAUDE_COMMAND_PROMPT_EXTEND:-}"

_zsh_claude_command_trim() {
  emulate -L zsh
  setopt extended_glob

  REPLY="${1##[[:space:]]#}"
  REPLY="${REPLY%%[[:space:]]#}"
}

_zsh_claude_command_classify_error() {
  emulate -L zsh

  case "${(L)1}" in
    *"rate limit"* | *"usage limit"* | *quota* | *"too many requests"* | *429*)
      REPLY="usage limit"
      ;;
    *"not authenticated"* | *unauthenticated* | *authentication* | *"login required"* \
      | *"please log in"* | *"invalid api key"* | *invalid_api_key* | *401* | *403*)
      REPLY="authentication"
      ;;
    *)
      REPLY=""
      ;;
  esac
}

_zsh_claude_command_normalize_response() {
  emulate -L zsh

  local response="${1//$'\r'/}"
  local backtick=$'\x60'
  local fence="${backtick}${backtick}${backtick}"

  _zsh_claude_command_trim "$response"
  response="$REPLY"

  if [[ "$response" == "$fence"* ]]; then
    response="${response#*$'\n'}"
    if [[ "${response[-4,-1]}" == $'\n'"$fence" ]]; then
      response="${response[1,-5]}"
    fi
    _zsh_claude_command_trim "$response"
    response="$REPLY"
  elif [[ "${response[1]}" == "$backtick" && "${response[-1]}" == "$backtick" ]]; then
    response="${response[2,-2]}"
  fi

  REPLY="$response"
}

_zsh_claude_command_ask_claude() {
  emulate -L zsh

  local query="$1"
  local system_prompt="$2"
  local -a args=(
    --print
    --output-format text
    --safe-mode
    --no-session-persistence
    --permission-prompts none
    --tools ''
    --effort low
    --system-prompt "$system_prompt"
  )

  if [[ -n "$ZSH_CLAUDE_COMMAND_MODEL" ]]; then
    args+=(--model "$ZSH_CLAUDE_COMMAND_MODEL")
  fi

  "@claude@" "${args[@]}" -- "$query"
}

_zsh_claude_command_ask_codex() {
  emulate -L zsh

  local query="$1"
  local system_prompt="$2"
  local temp_dir="$3"
  local prompt_file="$temp_dir/system-prompt"
  local response_file="$temp_dir/response"

  print -r -- "$system_prompt" >"$prompt_file"

  "@codex@" exec \
    --ephemeral \
    --ignore-user-config \
    --ignore-rules \
    --skip-git-repo-check \
    --sandbox read-only \
    --color never \
    --output-last-message "$response_file" \
    --config "model_instructions_file=\"$prompt_file\"" \
    -- "$query" \
    >/dev/null || return

  print -r -- "$(<"$response_file")"
}

_zsh_claude_command_accept_line() {
  # This is the hot path for every normal command: one builtin pattern match, then an immediate
  # handoff to Zsh's builtin accept-line widget. Pasted scripts arrive as multiline buffers and are
  # submitted normally too, so their comments never become AI requests.
  if [[ "$BUFFER" != '# '* || "$BUFFER" == *$'\n'* ]]; then
    zle .accept-line
    return
  fi

  # Options are reset only for requests, keeping the hot path above free of setup.
  emulate -L zsh
  setopt no_aliases pipe_fail

  _zsh_claude_command_trim "${BUFFER[3,-1]}"
  local query="$REPLY"

  if [[ -z "$query" ]]; then
    zle .accept-line
    return
  fi

  local system_prompt="You generate shell commands for an interactive zsh session.
Return exactly one syntactically correct, single-line command and nothing else.
Do not use Markdown, code fences, comments, or explanations.
The command must be safe to review: never claim that it has already run.
Operating system: $OSTYPE. Current directory: $PWD.
Prefer rg over grep, fd over find, bat over cat, and eza over ls."

  if [[ -n "$ZSH_CLAUDE_COMMAND_PROMPT_EXTEND" ]]; then
    system_prompt+=$'\n'"$ZSH_CLAUDE_COMMAND_PROMPT_EXTEND"
  fi

  zle -M "Generating command with Claude…"
  zle redisplay

  local temp_dir
  if ! temp_dir="$("@mktemp@" -d "${TMPDIR:-/tmp}/zsh-claude-command.XXXXXX")"; then
    zle -M "CLI error: could not create temporary files; your buffer was left unchanged"
    return 0
  fi

  local error_file="$temp_dir/error"
  local provider="Claude"
  local response exit_status claude_error_kind

  {
    response="$(_zsh_claude_command_ask_claude "$query" "$system_prompt" 2>"$error_file")"
    exit_status=$?

    if ((exit_status != 0)); then
      _zsh_claude_command_classify_error "$(<"$error_file")"
      claude_error_kind="$REPLY"

      if [[ -z "$claude_error_kind" ]]; then
        zle -M "CLI error: Claude failed (exit $exit_status); your buffer was left unchanged"
        return 0
      fi

      zle -M "Claude $claude_error_kind unavailable; trying Codex…"
      zle redisplay

      response="$(_zsh_claude_command_ask_codex "$query" "$system_prompt" "$temp_dir" 2>"$error_file")"
      exit_status=$?

      if ((exit_status != 0)); then
        _zsh_claude_command_classify_error "$(<"$error_file")"
        local codex_error="${REPLY:-failed (exit $exit_status)}"
        zle -M "CLI error: Claude $claude_error_kind; Codex $codex_error. Your buffer was left unchanged"
        return 0
      fi

      provider="Codex"
    fi
  } always {
    "@rm@" -rf -- "$temp_dir"
  }

  _zsh_claude_command_normalize_response "$response"
  response="$REPLY"

  if [[ -z "$response" || "$response" == *$'\n'* ]]; then
    zle -M "$provider returned an empty or multiline response; your buffer was left unchanged"
    return 0
  fi

  BUFFER="$response"
  CURSOR="${#BUFFER}"
  zle -M ""
  zle redisplay
}

zle -N accept-line _zsh_claude_command_accept_line
