#!/usr/bin/env bash

remote=${1:-}
url=${2:-}

refuse() {
  printf 'betterleaks pre-push: %s; push refused\n' "$1" >&2
  exit 1
}

command -v betterleaks >/dev/null 2>&1 || refuse "betterleaks is not installed"

updates=()
while read -r local_ref local_oid remote_ref remote_oid; do
  [[ -n ${local_oid:-} ]] || continue
  [[ $local_oid =~ ^0+$ ]] && continue
  updates+=("$local_ref $local_oid $remote_ref $remote_oid")
done
((${#updates[@]})) || exit 0

if [[ -n ${BETTERLEAKS_PUSH_BYPASS:-} ]]; then
  git_dir=$(git rev-parse --git-common-dir) || refuse "cannot find the repository to log the bypass"
  log="$git_dir/betterleaks-push-bypass.log"
  {
    printf '%s\tuser=%s\thost=%s\tcwd=%s\tremote=%s\turl=%s\treason=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(id -un)" "$(uname -n)" "$PWD" "$remote" "$url" \
      "$BETTERLEAKS_PUSH_BYPASS"
    printf '\t%s\n' "${updates[@]}"
  } >>"$log" || refuse "cannot write the bypass log $log"
  printf 'betterleaks pre-push: scan BYPASSED (%s), logged to %s\n' "$BETTERLEAKS_PUSH_BYPASS" "$log" >&2
  exit 0
fi

# Remote-tracking refs mark what the remote already has; a URL or an odd name excludes nothing.
exclude=()
if [[ $remote =~ ^[A-Za-z0-9._-]+$ ]] && git config --get "remote.$remote.url" >/dev/null 2>&1; then
  exclude=(--not "--remotes=$remote")
fi

scanned=0
for update in "${updates[@]}"; do
  read -r local_ref local_oid remote_ref remote_oid <<<"$update"
  if [[ ! $remote_oid =~ ^0+$ ]] && git cat-file -e "$remote_oid^{commit}" 2>/dev/null; then
    range=("$remote_oid..$local_oid")
  else
    range=("$local_oid" "${exclude[@]}")
  fi

  count=$(git rev-list --count "${range[@]}") || refuse "cannot list the commits for $local_ref"
  ((count)) || continue

  printf 'betterleaks pre-push: scanning %s commit(s) for %s -> %s\n' "$count" "$local_ref" "$remote_ref" >&2
  betterleaks git --no-banner --redact --verbose --log-level warn --log-opts="${range[*]}" . >&2 ||
    refuse "betterleaks found secrets or failed in $local_ref -> $remote_ref (status $?)"
  scanned=$((scanned + count))
done

((scanned == 0)) || printf 'betterleaks pre-push: %s commit(s) clean\n' "$scanned" >&2
