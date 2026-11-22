#!/bin/sh
# The marker preserves Orca's sandbox provenance matching without reaching the launcher.
if [ "${1-}" != orca-sandbox ]; then
  echo 'Orca: expected orca-sandbox marker' >&2
  exit 2
fi
shift
case "$(uname -s)" in
  Darwin)
    remaining=$PATH
    while :; do
      directory=${remaining%%:*}
      for candidate in "${directory:-.}"/sandbox-*; do
        if [ -f "$candidate" ] && [ -x "$candidate" ]; then
          exec "$candidate" "$@"
        fi
      done
      case $remaining in
        *:*) remaining=${remaining#*:} ;;
        *) break ;;
      esac
    done
    echo 'Orca: no executable sandbox-* command found in PATH' >&2
    exit 127
    ;;
  Linux) exec agent-sandbox-exec "$@" ;;
  *)
    echo 'Orca: unsupported sandbox host OS' >&2
    exit 1
    ;;
esac
