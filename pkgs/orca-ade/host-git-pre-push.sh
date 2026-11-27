# shellcheck shell=bash
input=$(
  cat
  echo .
)
input=${input%.}
for ((i = 0; i < ${ORCA_HOST_GIT_PRE_PUSH_COUNT:-0}; i++)); do
  name=ORCA_HOST_GIT_PRE_PUSH_$i
  sh -c "${!name} \"\$@\"" "${!name}" "$@" < <(printf '%s' "$input")
done
dir=${ORCA_HOST_GIT_PRE_PUSH_DIR:-}
if [[ -n $dir && -x $dir/pre-push ]]; then
  "$dir/pre-push" "$@" < <(printf '%s' "$input")
fi
