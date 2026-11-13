#!/usr/bin/env bash

# Logins, Steam (its client, logins, Proton prefixes and saves) and the caches
# the sandbox docs promise to keep survive; everything else in the shared
# sandbox home goes.
keep=(
  .claude.json
  .claude/.credentials.json
  .codex/auth.json
  .config/muse/auth.json
  .gemini/oauth_creds.json
  .local/share/opencode/auth.json
  .zcode/cli/config.json
  .ssh
  .orca-relay
  .steam
  .steampath
  .local/share/Steam
  .cache/sccache
  .cache/unreal-engine
)

usage() {
  echo 'usage: agent-sandbox-clean [--if-older-than DAYS]' >&2
  exit 2
}

min_age_days=
case ${1:-} in
  '') ;;
  --if-older-than)
    [[ ${2:-} =~ ^[0-9]+$ ]] || usage
    min_age_days=$2
    ;;
  *) usage ;;
esac

data=${XDG_DATA_HOME:-$HOME/.local/share}/agent-sandbox
home=$data/home
stamp=$data/last-clean

if [[ -n $min_age_days && -e $stamp ]] &&
  [[ -z $(find "$stamp" -maxdepth 0 -mtime "+$((min_age_days - 1))") ]]; then
  exit 0
fi

running=$(docker ps --format '{{.Names}}' --filter name=^agent-sandbox-)
if grep -qvx agent-sandbox-codex-server <<<"$running"; then
  echo 'agent-sandbox-clean: sandboxes are running; stop them with agent-sandbox-kill first' >&2
  exit 75
fi
# The shared Codex server works out of the home; the next launch starts it again.
systemctl --user stop agent-sandbox-codex-server.service

# Remove everything under $1 except kept paths, descending only into
# directories that contain one.
prune() {
  local dir=$1 rel=$2 entry name path k kept descend
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e $entry || -L $entry ]] || continue
    name=${entry##*/}
    path=${rel:+$rel/}$name
    kept='' descend=''
    for k in "${keep[@]}"; do
      if [[ $k == "$path" ]]; then
        kept=1
        break
      elif [[ $k == "$path"/* ]]; then
        descend=1
      fi
    done
    if [[ -n $kept ]]; then
      continue
    elif [[ -n $descend && -d $entry && ! -L $entry ]]; then
      prune "$entry" "$path"
    else
      # Orca uploads read-only directories.
      [[ -d $entry && ! -L $entry ]] && chmod -R u+w -- "$entry"
      rm -rf -- "$entry"
    fi
  done
}

before=$(du -sb "$home" 2>/dev/null | cut -f1)
[[ -d $home ]] && prune "$home" ''
chmod -R u+w -- "$data"/tmp
rm -rf -- "$data"/tmp/*
after=$(du -sb "$home" 2>/dev/null | cut -f1)
touch "$stamp"
echo "agent-sandbox-clean: freed $(numfmt --to=iec $((${before:-0} - ${after:-0}))), $(numfmt --to=iec "${after:-0}") kept"
