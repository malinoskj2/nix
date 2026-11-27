#!/usr/bin/env bash
usage() {
  cat <<'EOF'
Usage: secret <command> [args]

  init <recovery-recipient>  Create the host key and .sops.yaml for this host
  list                       Show each name, its consumer kind, and whether it's
                             in the file and deployed
  add <name> [--file PATH]   Add a secret, read from PATH, stdin or a prompt
  rotate <name> [--file PATH]
                             Replace an existing secret's value
  remove <name>              Delete a secret from the file
  edit                       Open the decrypted file in $EDITOR (shows values)
  recipients                 Print the public keys the file is encrypted to
  recipient-add <recipient>  Add an age public key, then re-encrypt
  rekey [--identity PATH]    Re-encrypt to the recipients in .sops.yaml
  apply                      Decrypt the file into /run/secrets now
  unlock                     Unwrap the host key with the login password, then apply
  lock                       Forget the unwrapped key and withdraw every secret
  rewrap                     Wrap the host key with a new login password
  migrate                    Wrap an existing plain host key, unchanged, then
                             delete the plain copy
  reset-key --identity PATH  Replace a host key nobody can unwrap, using the
                             recovery key
  backup <dir>               Copy the encrypted file and .sops.yaml to <dir>
  restore <file> [--identity PATH]
                             Install a backed-up encrypted file and re-encrypt it
                             for this host

Values are never printed, except by edit.
EOF
}

die() {
  echo "secret: $*" >&2
  exit 1
}

if [[ ${1-} == -h || ${1-} == --help || $# -eq 0 ]]; then
  usage
  exit 0
fi

umask 077
config=${SECRETS_CONFIG:-/etc/secrets/config.json}
if [[ -r $config ]]; then
  file=$(jq -r .file "$config")
  key=$(jq -r .keyFile "$config")
  unlock=$(jq -r '.unlock.enable' "$config")
  sealed=$(jq -r '.unlock.sealedKeyFile' "$config")
else
  unlock=false
  sealed=
  file=/var/lib/secrets/secrets.yaml
  key=/var/lib/sops-nix/key.txt
fi
dir=$(dirname "$file")
rules=$dir/.sops.yaml
legacy=/var/lib/sops-nix/key.txt

if ((EUID != 0)) && [[ ! -w $dir ]]; then
  exec sudo -- "$(readlink -f "$0")" "$@"
fi
export SOPS_AGE_KEY_FILE=$key

recipient_pattern='^age1[02-9ac-hj-np-z]{58}$'

valid_name() {
  [[ $1 =~ ^[A-Za-z0-9_-]+$ && $1 != sops ]] || die "invalid name '$1': use letters, digits, - and _"
}

has_key() {
  [[ -s $file ]] && NAME=$1 yq -e 'has(strenv(NAME))' "$file" >/dev/null 2>&1
}

need_unlocked() {
  [[ -s $key ]] || die "the secrets are locked; log in, or run 'secret unlock'"
}

do_apply() {
  systemctl restart sops-install-secrets.service || die "sops-install-secrets failed; see journalctl -u sops-install-secrets"
  systemctl is-active --quiet sops-install-secrets.service ||
    die "skipped: $(journalctl -u sops-install-secrets -n 1 -o cat --no-pager)"
  echo "Deployed to /run/secrets" >&2
  if [[ -r $config ]]; then
    while read -r name path; do
      [[ -e $path ]] || echo "secret: $name isn't in $file, so it stays undeployed" >&2
    done < <(jq -r '.secrets | to_entries[] | "\(.value.key) \(.value.path)"' "$config")
    # Services skipped while their secrets were missing don't start on their own.
    mapfile -t units < <(jq -r '.units[]' "$config")
    for unit in "${units[@]}"; do
      systemctl start "$unit" || echo "secret: $unit didn't start; see journalctl -u $unit" >&2
    done
  fi
}

need_rules() {
  [[ -s $rules ]] || die "no $rules yet; run secret init first"
}

run_sops() {
  sops --config "$rules" "$@"
}

# Prints the value as a JSON string on stdout, for piping straight into sops.
read_value() {
  local name=$1 source=$2 value confirm
  if [[ -n $source ]]; then
    [[ -r $source ]] || die "can't read $source"
    jq -Rs . <"$source"
  elif [[ -t 0 ]]; then
    read -rsp "Value for $name: " value </dev/tty
    echo >&2
    read -rsp "Again: " confirm </dev/tty
    echo >&2
    [[ $value == "$confirm" ]] || die "values differ"
    [[ -n $value ]] || die "empty value"
    printf '%s' "$value" | jq -Rs .
  else
    jq -Rs 'rtrimstr("\n")' | jq -e 'select(length > 0)' || die "empty value"
  fi
}

set_value() {
  local name=$1 source=$2 json tmp
  need_rules
  json=$(read_value "$name" "$source")
  if [[ -s $file ]]; then
    printf '%s' "$json" | run_sops set --value-stdin "$file" "[\"$name\"]"
  else
    tmp=$(mktemp "$dir/.secrets.XXXXXX")
    if ! printf '%s' "$json" | jq --arg name "$name" '{($name): .}' |
      run_sops encrypt --filename-override "$file" --input-type json --output-type yaml /dev/stdin >"$tmp"; then
      rm -f "$tmp"
      die "encryption failed"
    fi
    mv "$tmp" "$file"
  fi
}

parse_source() {
  source=
  identity=
  while (($#)); do
    case $1 in
      --file)
        source=${2:?--file needs a path}
        shift 2
        ;;
      --identity)
        identity=${2:?--identity needs a path}
        shift 2
        ;;
      *) die "unknown argument $1" ;;
    esac
  done
}

host_recipient() {
  yq -r '.creation_rules[0].age' "$rules" | cut -d, -f1
}

# Finishes a migration whose shred was interrupted: the plain copy is no longer a key, so the
# wrap is authenticated and checked against the configuration and the file instead.
finish_migration() {
  local keydir host
  keydir=$(dirname "$key")
  mkdir -p "$keydir"
  stage=$(mktemp -d "$keydir/migrate.XXXXXX")
  trap 'rm -rf -- "$stage"' EXIT
  secret-unlock unwrap-to "$stage/key.txt" || die "not finished; $legacy is unchanged"
  host=$(age-keygen -y "$stage/key.txt")
  [[ $host == "$(host_recipient)" ]] || die "$sealed doesn't hold this host's recipient; $legacy is unchanged"
  if [[ -s $file ]]; then
    SOPS_AGE_KEY_FILE=$stage/key.txt sops decrypt "$file" >/dev/null 2>&1 ||
      die "$sealed doesn't decrypt $file; $legacy is unchanged"
  fi
  exec 9>"$keydir/.lock"
  flock 9
  if [[ -s $key ]]; then
    [[ $(age-keygen -y "$key") == "$host" ]] || die "a different host key is unlocked; $legacy is unchanged"
  else
    mv "$stage/key.txt" "$key"
  fi
  flock -u 9
}

remind_apply() {
  echo "Run 'secret apply' to deploy it; services that use it restart." >&2
}

cmd=$1
shift
case $cmd in
  init)
    recovery=${1:?usage: secret init <recovery-recipient>}
    [[ $recovery =~ $recipient_pattern ]] || die "not an age public key: $recovery"
    [[ -e $rules ]] && die "$rules exists; use recipient-add"
    mkdir -p "$dir" "$(dirname "$key")"
    chmod 0700 "$dir" "$(dirname "$key")"
    if [[ $unlock == true ]]; then
      [[ -e $sealed ]] && die "$sealed exists; use rewrap to change its password"
      mkdir -p "$(dirname "$sealed")"
      chmod 0700 "$(dirname "$sealed")"
      [[ -s $key ]] || age-keygen -o "$key" 2>/dev/null
      secret-unlock init || die "the host key isn't wrapped yet; run init again"
      echo "Created the host key, wrapped in $sealed" >&2
    elif [[ ! -s $key ]]; then
      age-keygen -o "$key" 2>/dev/null
      echo "Created the host key $key" >&2
    fi
    host=$(age-keygen -y "$key")
    HOST=$host RECOVERY=$recovery yq -n '.creation_rules = [{"path_regex": "secrets\\.yaml$", "age": strenv(HOST) + "," + strenv(RECOVERY)}]' >"$rules"
    echo "Host recipient: $host"
    echo "Wrote $rules"
    ;;
  list)
    if [[ $unlock == true && -e $legacy ]]; then
      echo "secret: the host key is still plain in $legacy; run 'secret migrate'" >&2
    fi
    if [[ $unlock == true && -e $(dirname "$sealed")/rewrap-pending ]]; then
      echo "secret: the login password changed but the key keeps its old wrap; run 'secret rewrap'" >&2
    fi
    declared=()
    if [[ -r $config ]]; then
      mapfile -t declared < <(jq -r '.secrets | to_entries[] | "\(.value.key) \(.value.kind) \(.value.path)"' "$config")
    fi
    present=()
    if [[ -s $file ]]; then
      mapfile -t present < <(yq -r 'keys | .[] | select(. != "sops")' "$file")
    fi
    printf '%-32s %-7s %-8s %s\n' NAME KIND IN-FILE DEPLOYED
    declare -A seen=()
    for entry in "${declared[@]}"; do
      read -r name kind path <<<"$entry"
      seen[$name]=1
      in_file=no
      has_key "$name" && in_file=yes
      deployed=no
      [[ -e $path ]] && deployed=yes
      printf '%-32s %-7s %-8s %s\n' "$name" "$kind" "$in_file" "$deployed"
    done
    for name in "${present[@]}"; do
      [[ -n ${seen[$name]-} ]] || printf '%-32s %-7s %-8s %s\n' "$name" - yes -
    done
    ;;
  add)
    need_unlocked
    name=${1:?usage: secret add <name> [--file PATH]}
    shift
    valid_name "$name"
    parse_source "$@"
    has_key "$name" && die "$name exists; use rotate"
    set_value "$name" "$source"
    echo "Added $name to $file" >&2
    remind_apply
    ;;
  rotate)
    need_unlocked
    name=${1:?usage: secret rotate <name> [--file PATH]}
    shift
    valid_name "$name"
    parse_source "$@"
    has_key "$name" || die "$name isn't in $file; use add"
    set_value "$name" "$source"
    echo "Replaced $name. Revoke the old value at its provider once the new one works." >&2
    remind_apply
    ;;
  remove)
    need_unlocked
    name=${1:?usage: secret remove <name>}
    valid_name "$name"
    has_key "$name" || die "$name isn't in $file"
    need_rules
    run_sops unset "$file" "[\"$name\"]"
    echo "Removed $name. Remove its declaration from the flake too, or its services stay stopped." >&2
    remind_apply
    ;;
  edit)
    need_unlocked
    need_rules
    [[ -s $file ]] || die "no $file yet; use add"
    run_sops edit "$file"
    remind_apply
    ;;
  recipients)
    need_rules
    yq -r '.creation_rules[0].age' "$rules" | tr ',' '\n'
    ;;
  recipient-add)
    need_unlocked
    recipient=${1:?usage: secret recipient-add <recipient>}
    [[ $recipient =~ $recipient_pattern ]] || die "not an age public key: $recipient"
    need_rules
    if yq -r '.creation_rules[0].age' "$rules" | tr ',' '\n' | grep -qxF "$recipient"; then
      die "already a recipient"
    fi
    R=$recipient yq -i '.creation_rules[0].age += "," + strenv(R)' "$rules"
    [[ -s $file ]] && run_sops updatekeys --yes "$file"
    echo "Added $recipient" >&2
    ;;
  rekey)
    parse_source "$@"
    [[ -n $identity ]] && export SOPS_AGE_KEY_FILE=$identity
    [[ -n $identity ]] || need_unlocked
    need_rules
    [[ -s $file ]] || die "no $file yet"
    run_sops updatekeys --yes "$file"
    ;;
  apply)
    do_apply
    ;;
  unlock)
    [[ $unlock == true ]] || die "this host doesn't wrap its key"
    secret-unlock unlock || die "not unlocked"
    do_apply
    ;;
  lock)
    [[ $unlock == true ]] || die "this host doesn't wrap its key"
    secret-unlock lock
    systemctl restart sops-install-secrets.service || true
    echo "Locked: every secret is withdrawn until the next login or 'secret unlock'" >&2
    ;;
  reset-key)
    [[ $unlock == true ]] || die "this host doesn't wrap its key"
    parse_source "$@"
    [[ -n $identity ]] || die "usage: secret reset-key --identity <recovery key file>"
    need_rules
    if [[ -s $file ]]; then
      SOPS_AGE_KEY_FILE=$identity sops decrypt "$file" >/dev/null 2>&1 ||
        die "$identity doesn't decrypt $file; nothing was changed"
    fi
    keydir=$(dirname "$key")
    mkdir -p "$keydir"
    # Staged on the key's ramfs; the live key, wrap, rules and file stay until everything checks out.
    stage=$(mktemp -d "$keydir/reset.XXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    age-keygen -o "$stage/key.txt" 2>/dev/null
    secret-unlock wrap-into "$stage/key.txt" "$stage/key.sealed" || die "not wrapped; nothing was changed"
    old_host=$(yq -r '.creation_rules[0].age' "$rules" | cut -d, -f1)
    new_host=$(age-keygen -y "$stage/key.txt")
    mkdir "$stage/data"
    OLD=$old_host NEW=$new_host yq '.creation_rules[0].age |= sub(strenv(OLD), strenv(NEW))' "$rules" >"$stage/data/.sops.yaml"
    if [[ -s $file ]]; then
      cp "$file" "$stage/data/secrets.yaml"
      SOPS_AGE_KEY_FILE=$identity sops --config "$stage/data/.sops.yaml" updatekeys --yes "$stage/data/secrets.yaml" ||
        die "re-encryption failed; nothing was changed"
      SOPS_AGE_KEY_FILE=$stage/key.txt sops decrypt "$stage/data/secrets.yaml" >/dev/null 2>&1 ||
        die "the new host key doesn't decrypt the re-encrypted file; nothing was changed"
    fi
    # Every intermediate state stays decryptable with the recovery key, so an interrupted
    # commit is finished by running reset-key again.
    exec 9>"$keydir/.lock"
    flock 9
    cp "$stage/key.sealed" "$sealed.new"
    cp "$stage/data/.sops.yaml" "$rules.new"
    [[ -s $file ]] && cp "$stage/data/secrets.yaml" "$file.new"
    [[ -e $sealed ]] && cp "$sealed" "$sealed.old"
    [[ -s $file ]] && mv "$file.new" "$file"
    mv "$rules.new" "$rules"
    mv "$sealed.new" "$sealed"
    mv "$stage/key.txt" "$key"
    rm -f -- "$sealed.old"
    flock -u 9
    echo "Replaced the host key $old_host with $new_host" >&2
    do_apply
    ;;
  migrate)
    [[ $unlock == true ]] || die "this host doesn't wrap its key"
    [[ -e $legacy ]] || die "no plain host key at $legacy to migrate"
    need_rules
    if [[ -e $sealed ]] && ! age-keygen -y "$legacy" >/dev/null 2>&1; then
      finish_migration
      host=$(host_recipient)
    else
      host=$(age-keygen -y "$legacy") || die "$legacy isn't an age key"
      # The host recipient is always the first; the others, like the recovery key, must never be unwrapped here.
      [[ $(host_recipient) == "$host" ]] || die "$legacy isn't this host's recipient in $rules"
      if [[ -s $file ]]; then
        SOPS_AGE_KEY_FILE=$legacy sops decrypt "$file" >/dev/null 2>&1 || die "$legacy doesn't decrypt $file"
      fi
      secret-unlock migrate "$legacy" || die "not migrated; $legacy is unchanged"
      [[ $(age-keygen -y "$key") == "$host" ]] || die "the unlocked key isn't $host; $legacy is unchanged"
      if [[ -s $file ]]; then
        sops decrypt "$file" >/dev/null 2>&1 || die "the wrapped key doesn't decrypt $file; $legacy is unchanged"
      fi
    fi
    shred -u "$legacy" || die "wrapped, but $legacy wasn't deleted; run 'secret migrate' again"
    sync -f "$(dirname "$legacy")"
    echo "Wrapped the host key $host in $sealed and deleted $legacy" >&2
    do_apply
    ;;
  rewrap)
    [[ $unlock == true ]] || die "this host doesn't wrap its key"
    secret-unlock rewrap || die "not rewrapped; the key keeps its old wrap"
    echo "Rewrapped $sealed" >&2
    do_apply
    ;;
  backup)
    dest=${1:?usage: secret backup <dir>}
    [[ -d $dest ]] || die "$dest isn't a directory"
    [[ -s $file ]] || die "no $file yet"
    stamp=$(date +%Y%m%d-%H%M%S)
    host=$(cat /proc/sys/kernel/hostname)
    cp --no-clobber "$file" "$dest/secrets-$host-$stamp.yaml"
    [[ -s $rules ]] && cp --no-clobber "$rules" "$dest/sops-$host-$stamp.yaml"
    echo "Copied the encrypted file to $dest/secrets-$host-$stamp.yaml" >&2
    ;;
  restore)
    src=${1:?usage: secret restore <file> [--identity PATH]}
    shift
    parse_source "$@"
    [[ -n $identity ]] && export SOPS_AGE_KEY_FILE=$identity
    need_rules
    yq -e '.sops.mac' "$src" >/dev/null 2>&1 || die "$src isn't a sops-encrypted YAML file"
    staging=$(mktemp -d "$dir/.restore.XXXXXX")
    cp "$src" "$staging/secrets.yaml"
    if ! run_sops updatekeys --yes "$staging/secrets.yaml"; then
      rm -rf "$staging"
      die "re-encryption failed; pass --identity with a key the backup was encrypted to"
    fi
    [[ -e $file ]] && mv "$file" "$file.$(date +%Y%m%d-%H%M%S).bak"
    mv "$staging/secrets.yaml" "$file"
    rmdir "$staging"
    echo "Restored $file" >&2
    remind_apply
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
