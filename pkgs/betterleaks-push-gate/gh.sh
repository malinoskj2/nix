#!/usr/bin/env bash
real=@gh@

refuse() {
  printf 'gh %s is disabled: it writes to a GitHub repository without git, so the Betterleaks pre-push scan cannot check it.\n' "$1" >&2
  printf 'Push with plain git instead (git fetch, git merge, git push).\n' >&2
  exit 1
}

case ${1:-} in
  repo)
    for arg in "${@:2}"; do
      [[ $arg == sync ]] && refuse "repo sync"
      [[ $arg == -* ]] || break
    done
    ;;
  api)
    method=
    fields=0
    input=
    endpoint=
    bodies=()
    args=("${@:2}")
    i=0
    while ((i < ${#args[@]})); do
      arg=${args[i]}
      next=${args[i + 1]:-}
      case $arg in
        -X | --method) method=$next i=$((i + 1)) ;;
        -X* | --method=*) method=${arg#-X} method=${method#--method=} ;;
        -f | -F | --field | --raw-field) fields=1 bodies+=("$next") i=$((i + 1)) ;;
        -f* | -F* | --field=* | --raw-field=*) fields=1 bodies+=("$arg") ;;
        --input) input=$next i=$((i + 1)) ;;
        --input=*) input=${arg#--input=} ;;
        -H | --header | -q | --jq | -t | --template | --hostname | --cache | -p | --preview) i=$((i + 1)) ;;
        -*) ;;
        *) [[ -n $endpoint ]] || endpoint=$arg ;;
      esac
      i=$((i + 1))
    done

    if [[ -z $method ]]; then
      if ((fields)) || [[ -n $input ]]; then method=POST; else method=GET; fi
    fi
    method=${method^^}

    if [[ ${endpoint#/} == graphql ]]; then
      [[ $input == - ]] && refuse "api graphql with a query on stdin (it cannot be checked)"
      if [[ -n $input ]]; then
        @grep@ -q createCommitOnBranch -- "$input" 2>/dev/null && refuse "api graphql createCommitOnBranch"
      fi
      for body in "${bodies[@]}"; do
        [[ $body == *createCommitOnBranch* ]] && refuse "api graphql createCommitOnBranch"
        if [[ $body == *=@* ]]; then
          file=${body#*=@}
          [[ $file == - ]] && refuse "api graphql with a query on stdin (it cannot be checked)"
          @grep@ -q createCommitOnBranch -- "$file" 2>/dev/null && refuse "api graphql createCommitOnBranch"
        fi
      done
    elif [[ $method != GET && $method != HEAD ]]; then
      case /${endpoint#/} in
        */git/blobs* | */git/trees* | */git/commits* | */git/tags* | */git/refs* | */contents/* | */merge-upstream*)
          refuse "api $method $endpoint"
          ;;
      esac
    fi
    ;;
esac

exec "$real" "$@"
