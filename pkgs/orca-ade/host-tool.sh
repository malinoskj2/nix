# shellcheck shell=bash
tool=${0##*/}
dir=${ORCA_HOST_GIT_PATH:?}
PATH=:$PATH:
PATH=${PATH//:$dir:/:}
PATH=${PATH#:}
PATH=${PATH%:}
real=$(command -v "$tool") || {
  # Orca reports a missing CLI from a spawn error in this form.
  echo "spawn $tool ENOENT" >&2
  exit 127
}
PATH=$dir:$PATH exec "$real" "$@"
