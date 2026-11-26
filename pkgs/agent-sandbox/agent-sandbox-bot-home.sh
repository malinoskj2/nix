#!/usr/bin/env bash

bots=$HOME/.orca/bots
here=$(pwd -P)

# Ancestry is judged on resolved paths, and the directory is reported under the
# launcher's ~/.orca/bots mount so the container starts in the same place.
if bots_real=$(cd "$bots" 2>/dev/null && pwd -P) && [[ $here == "$bots_real"/?* ]]; then
  relative=${here#"$bots_real"/}
  printf '%s\n%s\n' "${relative%%/*}" "$bots/$relative"
  exit 0
fi
# A path that only looks like a bot home must not fall through to another launch.
if [[ $PWD == "$bots"/?* ]]; then
  echo "agent-sandbox: $PWD resolves to $here, outside $bots" >&2
  exit 2
fi
exit 1
