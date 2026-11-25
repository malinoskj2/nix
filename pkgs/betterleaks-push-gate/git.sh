#!/usr/bin/env bash
real=@git@
case " $* " in
  *push*) ;;
  *) exec "$real" "$@" ;;
esac

args=("$@")
i=0
while ((i < ${#args[@]})); do
  case ${args[i]} in
    -C | -c | --git-dir | --work-tree | --namespace | --super-prefix | --attr-source) i=$((i + 2)) ;;
    -*) i=$((i + 1)) ;;
    *) break ;;
  esac
done

if [[ ${args[i]:-} == push ]]; then
  for arg in "${args[@]:i+1}"; do
    [[ $arg == -- ]] && break
    # Git accepts any unambiguous prefix of a long option.
    if [[ $arg == --no-veri* && --no-verify == "$arg"* ]]; then
      printf 'git push --no-verify is disabled: it skips the Betterleaks secret scan.\n' >&2
      printf 'For an emergency, run BETTERLEAKS_PUSH_BYPASS="<reason>" git push, which is logged.\n' >&2
      exit 1
    fi
  done
fi

exec "$real" "$@"
