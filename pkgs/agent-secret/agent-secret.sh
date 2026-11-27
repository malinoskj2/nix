#!/usr/bin/env bash
usage() {
  cat <<'EOF'
Usage: agent-secret <command> [args]

  init <recovery-recipient>  Create the host key and .sops.yaml for this host
  list                       Show secret names: in the file, declared, deployed
  add <name> [--file PATH]   Add a secret, read from PATH, stdin or a prompt
  rotate <name> [--file PATH]
                             Replace an existing secret's value
  remove <name>              Delete a secret from the file
  edit                       Open the decrypted file in $EDITOR (shows values)
  recipients                 Print the public keys the file is encrypted to
  recipient-add <recipient>  Add an age public key, then re-encrypt
  rekey [--identity PATH]    Re-encrypt to the recipients in .sops.yaml
  apply                      Decrypt the file into /run/secrets now
  backup <dir>               Copy the encrypted file and .sops.yaml to <dir>
  restore <file> [--identity PATH]
                             Install a backed-up encrypted file and re-encrypt it
                             for this host

Values are never printed, except by edit.
EOF
}

die() {
  echo "agent-secret: $*" >&2
  exit 1
}

if [[ ${1-} == -h || ${1-} == --help || $# -eq 0 ]]; then
  usage
  exit 0
fi

umask 077
config=${AGENT_SECRETS_CONFIG:-/etc/agent-secrets/config.json}
if [[ -r $config ]]; then
  file=$(jq -r .secretsFile "$config")
  key=$(jq -r .keyFile "$config")
else
  file=/var/lib/agent-secrets/secrets.yaml
  key=/var/lib/sops-nix/key.txt
fi
dir=$(dirname "$file")
rules=$dir/.sops.yaml

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

need_rules() {
  [[ -s $rules ]] || die "no $rules yet; run agent-secret init first"
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

remind_apply() {
  echo "Run 'agent-secret apply' to deploy it; services that use it restart." >&2
}

cmd=$1
shift
case $cmd in
  init)
    recovery=${1:?usage: agent-secret init <recovery-recipient>}
    [[ $recovery =~ $recipient_pattern ]] || die "not an age public key: $recovery"
    [[ -e $rules ]] && die "$rules exists; use recipient-add"
    mkdir -p "$dir" "$(dirname "$key")"
    chmod 0700 "$dir" "$(dirname "$key")"
    if [[ ! -s $key ]]; then
      age-keygen -o "$key" 2>/dev/null
      echo "Created the host key $key" >&2
    fi
    host=$(age-keygen -y "$key")
    HOST=$host RECOVERY=$recovery yq -n '.creation_rules = [{"path_regex": "secrets\\.yaml$", "age": strenv(HOST) + "," + strenv(RECOVERY)}]' >"$rules"
    echo "Host recipient: $host"
    echo "Wrote $rules"
    ;;
  list)
    declared=()
    if [[ -r $config ]]; then
      mapfile -t declared < <(jq -r '.secrets | to_entries[] | "\(.value.key) \(.value.path)"' "$config")
    fi
    present=()
    if [[ -s $file ]]; then
      mapfile -t present < <(yq -r 'keys | .[] | select(. != "sops")' "$file")
    fi
    printf '%-32s %-8s %-9s %s\n' NAME IN-FILE DECLARED DEPLOYED
    declare -A seen=()
    for entry in "${declared[@]}"; do
      name=${entry%% *}
      path=${entry#* }
      seen[$name]=1
      in_file=no
      has_key "$name" && in_file=yes
      deployed=no
      [[ -e $path ]] && deployed=yes
      printf '%-32s %-8s %-9s %s\n' "$name" "$in_file" yes "$deployed"
    done
    for name in "${present[@]}"; do
      [[ -n ${seen[$name]-} ]] || printf '%-32s %-8s %-9s %s\n' "$name" yes no -
    done
    ;;
  add)
    name=${1:?usage: agent-secret add <name> [--file PATH]}
    shift
    valid_name "$name"
    parse_source "$@"
    has_key "$name" && die "$name exists; use rotate"
    set_value "$name" "$source"
    echo "Added $name to $file" >&2
    remind_apply
    ;;
  rotate)
    name=${1:?usage: agent-secret rotate <name> [--file PATH]}
    shift
    valid_name "$name"
    parse_source "$@"
    has_key "$name" || die "$name isn't in $file; use add"
    set_value "$name" "$source"
    echo "Replaced $name. Revoke the old value at its provider once the new one works." >&2
    remind_apply
    ;;
  remove)
    name=${1:?usage: agent-secret remove <name>}
    valid_name "$name"
    has_key "$name" || die "$name isn't in $file"
    need_rules
    run_sops unset "$file" "[\"$name\"]"
    echo "Removed $name. Remove its declaration from the flake too, or its services stay stopped." >&2
    remind_apply
    ;;
  edit)
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
    recipient=${1:?usage: agent-secret recipient-add <recipient>}
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
    need_rules
    [[ -s $file ]] || die "no $file yet"
    run_sops updatekeys --yes "$file"
    ;;
  apply)
    systemctl restart sops-install-secrets.service || die "sops-install-secrets failed; see journalctl -u sops-install-secrets"
    systemctl is-active --quiet sops-install-secrets.service ||
      die "skipped: $(journalctl -u sops-install-secrets -n 1 -o cat --no-pager)"
    echo "Deployed to /run/secrets" >&2
    if [[ -r $config ]]; then
      # Services skipped while their secrets were missing don't start on their own.
      mapfile -t units < <(jq -r '.services[]' "$config")
      for unit in "${units[@]}"; do
        systemctl start "$unit" || echo "agent-secret: $unit didn't start; see journalctl -u $unit" >&2
      done
    fi
    ;;
  backup)
    dest=${1:?usage: agent-secret backup <dir>}
    [[ -d $dest ]] || die "$dest isn't a directory"
    [[ -s $file ]] || die "no $file yet"
    stamp=$(date +%Y%m%d-%H%M%S)
    host=$(cat /proc/sys/kernel/hostname)
    cp --no-clobber "$file" "$dest/secrets-$host-$stamp.yaml"
    [[ -s $rules ]] && cp --no-clobber "$rules" "$dest/sops-$host-$stamp.yaml"
    echo "Copied the encrypted file to $dest/secrets-$host-$stamp.yaml" >&2
    ;;
  restore)
    src=${1:?usage: agent-secret restore <file> [--identity PATH]}
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
