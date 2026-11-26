# shellcheck shell=bash
args=()
while (($#)); do
  case $1 in
    --)
      args+=("$@")
      break
      ;;
    # Lets the TUI's Cloud backend (Ctrl-X B, then Ctrl-X E) see ChatGPT Work cloud environments.
    --cloud) args=(--enable tui_multi_backend "${args[@]}") ;;
    *) args+=("$1") ;;
  esac
  shift
done

exec "$CODEX" "${args[@]}"
