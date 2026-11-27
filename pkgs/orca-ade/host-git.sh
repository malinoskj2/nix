# shellcheck shell=bash

# gh and glab find this wrapper as git on PATH, ahead of the real one.
if [[ -n ${ORCA_HOST_GIT_PATH:-} ]]; then
  PATH=:$PATH:
  PATH=${PATH//:$ORCA_HOST_GIT_PATH:/:}
  PATH=${PATH#:}
  PATH=${PATH%:}
fi
real=$(type -P "${ORCA_HOST_GIT_REAL:-@git@}") || {
  echo 'spawn git ENOENT' >&2
  exit 127
}
bwrap=${ORCA_HOST_GIT_BWRAP:-@bwrap@}
pre_push_dir=@prepush@

fail() {
  echo "fatal: orca-host-git: $*" >&2
  exit 128
}

globals=()
while (($#)); do
  case $1 in
    -C)
      if [[ -n $2 ]]; then
        cd -- "$2" || exit 128
      fi
      shift 2
      ;;
    -c | --git-dir | --work-tree | --namespace | --config-env)
      globals+=("$1" "$2")
      shift 2
      ;;
    --git-dir=* | --work-tree=* | --namespace=* | --config-env=* | --attr-source=* | --bare | \
      --no-replace-objects | --no-lazy-fetch | --no-advice | --no-optional-locks | --literal-pathspecs | \
      --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs)
      globals+=("$1")
      shift
      ;;
    -p | -P | --paginate | --no-pager) shift ;;
    --version | -v | --help | -h) break ;;
    -*) fail "unsupported option $1" ;;
    *) break ;;
  esac
done
sub=${1:-}
cwd=$PWD

# Only system, global and Orca's own command-line config are trusted. Repository config is never
# enumerated, because it can change between any two reads: every program it could name is pinned.
declare -A trusted=() pre_push_names=() hook_commands=()
helpers=()
pre_push=()
while IFS= read -r -d '' _ && IFS= read -r -d '' rest; do
  key=${rest%%$'\n'*}
  value=
  [[ $rest == *$'\n'* ]] && value=${rest#*$'\n'}
  trusted[${key,,}]=$value
  case ${key,,} in
    credential.*helper) helpers+=("$key=$value") ;;
    hook.*.event)
      if [[ $value == pre-push && -z ${pre_push_names[${key:5:-6}]-} ]]; then
        pre_push_names[${key:5:-6}]=1
        pre_push+=("${key:5:-6}")
      fi
      ;;
    hook.*.command) hook_commands[${key:5:-8}]=$value ;;
  esac
done < <(cd / && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_CONFIG \
  GIT_PAGER='cat' "$real" config --list --show-scope -z 2>/dev/null)

overrides=(-c core.fsmonitor=false -c core.pager=cat -c core.alternateRefsCommand=true)
# Housekeeping prunes worktrees, and in the jail every one outside the repository looks deleted.
# On the host it reads gc.recentObjectsHook, a list that a command-line value only adds to.
overrides+=(-c gc.auto=0 -c maintenance.auto=false)
pin() {
  local key=${1,,}
  overrides+=(-c "$1=${trusted[$key]-$2}")
}
pin core.askPass ''
pin core.sshCommand ssh
pin gpg.program gpg
pin gpg.openpgp.program gpg
pin gpg.x509.program gpgsm
pin gpg.ssh.program ssh-keygen
pin gpg.ssh.defaultKeyCommand ''
# An empty helper empties the list, URL-scoped helpers included, before the trusted ones return.
overrides+=(-c credential.helper=)
for helper in "${helpers[@]}"; do
  overrides+=(-c "$helper")
done
export GIT_PAGER='cat' GIT_EDITOR=: GIT_SEQUENCE_EDITOR=:

# Outside the jail, no hook the repository configures or keeps in its hooks directory runs.
events=(
  applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg
  commit-msg post-commit pre-rebase post-checkout post-merge pre-push pre-receive update proc-receive
  post-receive post-update reference-transaction push-to-checkout pre-auto-gc post-rewrite
  sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist
  p4-pre-submit post-index-change
)
host_overrides=("${overrides[@]}")
host_overrides+=(-c "core.hooksPath=${trusted["core.hookspath"]-/dev/null}")
host_overrides+=(-c fetch.writeCommitGraph=false)
for event in "${events[@]}"; do
  host_overrides+=(-c "hook.$event.enabled=false")
done

protocols=${ORCA_HOST_GIT_PROTOCOLS:-https:http:ssh}

host_run() {
  GIT_ALLOW_PROTOCOL=$protocols "$real" --no-pager "${globals[@]}" "${host_overrides[@]}" "$@"
}

host() {
  GIT_ALLOW_PROTOCOL=$protocols exec "$real" --no-pager "${globals[@]}" "${host_overrides[@]}" "$@"
}

inside() {
  [[ $1 == "$2" || $1 == "$2"/* ]]
}

# Repository files choose these paths, so only the work tree Orca chose and the administrative
# directories that belong to it may be exposed to the repository's own programs: its .git, a
# superproject's .git, or the Git directory that lists it under worktrees/.
admin_dir() {
  local path=$1 anchor
  [[ -n $top ]] && inside "$path" "$top" && return 0
  anchor=${top:-$cwd}
  while [[ -n $anchor ]]; do
    inside "$path" "${anchor%/}/.git" && return 0
    [[ $anchor == / ]] && break
    anchor=${anchor%/*}
    anchor=${anchor:-/}
  done
  [[ ${gitdir%/*} == "$common/worktrees" && $common == *.git ]] && [[ $path == "$gitdir" || $path == "$common" ]]
}

physical() {
  cd -P -- "$1" 2>/dev/null && printf '%s' "$PWD"
}

# Sandboxes can write around these but not in them.
home=$(physical "$HOME") || home=$HOME
protected=("$home" "$home/.orca/bots/tohru")

extra=()
bind_parent() {
  local path=$1 parent
  [[ $path == /* ]] || path=$cwd/$path
  parent=$(physical "${path%/*}/") || return 0
  extra+=("$parent")
}

# The work tree Git would use without repository config: the caller's --work-tree, the caller's
# directory with an explicit Git directory, or the nearest directory with a .git.
work_root() {
  local dir=$cwd i tree='' named=${GIT_DIR:-}
  for ((i = 0; i < ${#globals[@]}; i++)); do
    case ${globals[i]} in
      --work-tree) tree=${globals[i + 1]} ;;
      --work-tree=*) tree=${globals[i]#--work-tree=} ;;
      --git-dir | --git-dir=*) named=1 ;;
    esac
  done
  [[ -z $tree ]] && tree=${GIT_WORK_TREE:-}
  if [[ -n $tree ]]; then
    physical "$tree"
    return
  fi
  [[ -n $named ]] && printf '%s' "$cwd" && return
  while [[ ! -e $dir/.git ]]; do
    [[ $dir == / ]] && return 1
    dir=${dir%/*}
    dir=${dir:-/}
  done
  printf '%s' "$dir"
}

# The jail mounts the directory each path named when it was checked, through an open descriptor,
# so a path swapped for a symlink afterwards changes nothing.
binds=()
guarded_path() {
  local p
  for p in "${protected[@]}"; do
    inside "$p" "$1" && return 0
  done
  return 1
}

expose() {
  local path=$1 fd
  guarded_path "$path" && fail "won't expose $path"
  cd -P -- "$path" 2>/dev/null || fail "no such directory: $path"
  exec {fd}<.
  cd / || exit 128
  [[ $(readlink "/proc/self/fd/$fd") == "$path" ]] || fail "$path moved while it was checked"
  binds+=(--bind-fd "$fd" "$path")
}

# Anything that can run a filter, diff driver, merge driver or hook runs here: no network, no home
# directory, /run or /tmp, and only the repository writable. Its programs then reach nothing a
# sandbox can't already reach.
jail() {
  local info lines top='' gitdir='' common='' path name paths=()
  cd -P -- "$cwd" 2>/dev/null || fail "no such directory: $cwd"
  cwd=$PWD
  # Paths come back canonical, and expose refuses any that isn't.
  info=$(host_run rev-parse --path-format=absolute --git-dir --git-common-dir --is-inside-work-tree \
    --show-toplevel 2>/dev/null) || true
  mapfile -t lines <<<"$info"
  if ((${#lines[@]} >= 3)); then
    # A path with a newline in it would shift the rest.
    [[ ${#lines[@]}:${lines[2]} == 4:true || ${#lines[@]}:${lines[2]} == [34]:false ]] ||
      fail "can't read the repository's paths"
    gitdir=${lines[0]}
    common=${lines[1]}
    if [[ ${lines[2]} == true ]]; then
      top=${lines[3]}
      [[ $top == "$(work_root)" ]] || fail "refusing work tree $top for $cwd"
      inside "$cwd" "$top" || fail "work tree $top doesn't contain $cwd"
      paths+=("$top")
    else
      inside "$cwd" "$gitdir" || fail "$gitdir doesn't contain $cwd"
    fi
    admin_dir "$gitdir" || fail "refusing Git directory $gitdir"
    admin_dir "$common" || fail "refusing common directory $common"
    for path in "$gitdir" "$common"; do
      [[ -n $top ]] && inside "$path" "$top" && continue
      paths+=("$path")
    done
  elif ! guarded_path "$cwd"; then
    paths+=("$cwd")
  fi
  for path in "${paths[@]}" "${extra[@]}"; do
    expose "$path"
  done

  local args=(
    "$bwrap" --die-with-parent --new-session --unshare-all
    --ro-bind / / --dev /dev --proc /proc
  )
  local hidden=()
  for path in /tmp /var/tmp /run /mnt /media /srv /home "$HOME"; do
    [[ -d $path ]] && args+=(--tmpfs "$path") && hidden+=("$path")
  done
  args+=(--ro-bind-try /run/current-system /run/current-system)
  local excludes attributes
  excludes=${trusted["core.excludesfile"]-}
  attributes=${trusted["core.attributesfile"]-}
  for path in "$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git" "${GIT_CONFIG_GLOBAL:-}" \
    "${excludes/#\~/$HOME}" "${attributes/#\~/$HOME}"; do
    [[ -n $path && -e $path ]] && args+=(--ro-bind "$path" "$path")
  done
  # Writes outside the repository fail instead of landing on a tmpfs that vanishes. Only the
  # temporary directories, where textconv and diff drivers get their files, stay writable. A
  # remount reaches every mount below it, so the repository is mounted after.
  for path in "${paths[@]}" "${extra[@]}"; do
    args+=(--dir "$path")
  done
  for path in "${hidden[@]}"; do
    [[ $path == /tmp || $path == /var/tmp ]] || args+=(--remount-ro "$path")
  done
  args+=("${binds[@]}")
  args+=(--chdir "$cwd" --clearenv)
  for name in PATH HOME USER LOGNAME LANG LANGUAGE TZ TERM NO_COLOR XDG_CONFIG_HOME "${!LC_@}" "${!GIT_@}"; do
    [[ -v $name ]] && args+=(--setenv "$name" "${!name}")
  done
  args+=(--setenv GIT_ALLOW_PROTOCOL file)
  exec "${args[@]}" "$real" --no-pager "${globals[@]}" "${overrides[@]}" "$@"
}

# Repository config can't add or change a pre-push hook: the trusted ones run from a fixed hooks
# directory, which runs every hook that system and global config name for pre-push.
push() {
  local i=0 name enabled dir
  for name in "${pre_push[@]}"; do
    enabled=hook.${name,,}.enabled
    [[ ${trusted[$enabled]-true} == false ]] && continue
    [[ -n ${hook_commands[$name]-} ]] || continue
    export "ORCA_HOST_GIT_PRE_PUSH_$i=${hook_commands[$name]}"
    i=$((i + 1))
  done
  export ORCA_HOST_GIT_PRE_PUSH_COUNT=$i
  unset ORCA_HOST_GIT_PRE_PUSH_DIR
  dir=${trusted["core.hookspath"]-}
  [[ -n $dir ]] && export ORCA_HOST_GIT_PRE_PUSH_DIR=${dir/#\~/$HOME}
  host_overrides+=(-c "core.hooksPath=$pre_push_dir")
  host "$@"
}

# The network half runs on the host and the merge in the jail, from a ref the fetch left behind.
pull() {
  shift
  local fetch=() merge=() positional=() remote upstream branch dry=0 ended=0
  ref=refs/orca-host-git/pull-$$
  while (($#)); do
    if ((ended)); then
      positional+=("$1")
      shift
      continue
    fi
    case $1 in
      -q | --quiet | -v | --verbose | --progress | --no-progress | --recurse-submodules | \
        --recurse-submodules=* | --no-recurse-submodules)
        fetch+=("$1")
        merge+=("$1")
        ;;
      --depth | --deepen | --shallow-since | --shallow-exclude | -o | --server-option | --upload-pack | \
        -j | --jobs | --negotiation-tip | --refmap)
        fetch+=("$1" "$2")
        shift
        ;;
      --all | -a | --append | --atomic | -f | --force | -k | --keep | --prune | --no-prune | -t | --tags | \
        --no-tags | --unshallow | --update-shallow | --set-upstream | --show-forced-updates | \
        --no-show-forced-updates | -4 | --ipv4 | -6 | --ipv6 | --depth=* | --deepen=* | --shallow-since=* | \
        --shallow-exclude=* | --server-option=* | --upload-pack=* | --jobs=* | --negotiation-tip=* | --refmap=*)
        fetch+=("$1")
        ;;
      --dry-run)
        fetch+=("$1")
        dry=1
        ;;
      -s | --strategy | -X | --strategy-option)
        merge+=("$1" "$2")
        shift
        ;;
      --) ended=1 ;;
      -*) merge+=("$1") ;;
      *) positional+=("$1") ;;
    esac
    shift
  done
  if [[ ${positional[0]:-} == . ]]; then
    jail pull "${fetch[@]}" "${merge[@]}" -- "${positional[@]}"
  fi
  if ((${#positional[@]} == 2)); then
    host_run fetch "${fetch[@]}" -- "${positional[@]}" || exit
    ((dry)) && exit
    host_run update-ref "$ref" FETCH_HEAD || exit
    trap 'host_run update-ref -d "$ref"' EXIT
    (jail pull "${merge[@]}" -- . "$ref")
    exit
  fi
  ((${#positional[@]} <= 2)) || fail "pull takes at most one branch"
  branch=$(host_run symbolic-ref --short HEAD) || exit
  remote=$(host_run config --get "branch.$branch.remote") || fail "$branch has no upstream to pull"
  if ((${#positional[@]})) && [[ ${positional[0]} != "$remote" ]]; then
    fail "pull from ${positional[0]} needs a branch: $branch tracks $remote"
  fi
  upstream=$(host_run rev-parse --symbolic-full-name '@{upstream}') || exit
  if [[ $remote != . ]]; then
    if [[ " ${fetch[*]} " == *' --all '* ]]; then
      host_run fetch "${fetch[@]}" || exit
    else
      host_run fetch "${fetch[@]}" -- "$remote" || exit
    fi
  fi
  ((dry)) && exit
  jail pull "${merge[@]}" -- . "$upstream"
}

# The clone runs on the host without a checkout, and the checkout in the jail.
clone() {
  local args=("$@") source='' dest='' count=0 checkout=1 ended=0 i
  for ((i = 1; i < ${#args[@]}; i++)); do
    case $ended:${args[i]} in
      0:--) ended=1 ;;
      1:*)
        count=$((count + 1))
        ((count == 1)) && source=${args[i]}
        ((count == 2)) && dest=${args[i]}
        ;;
      *)
        case ${args[i]} in
          -o | --origin | -b | --branch | -u | --upload-pack | --reference | --reference-if-able | --separate-git-dir | \
            -c | --config | --depth | --shallow-since | --shallow-exclude | --server-option | -j | --jobs | --template | \
            --filter | --bundle-uri | --ref-format | --revision) i=$((i + 1)) ;;
          -n | --no-checkout | --bare | --mirror) checkout=0 ;;
          -*) ;;
          *)
            count=$((count + 1))
            ((count == 1)) && source=${args[i]}
            ((count == 2)) && dest=${args[i]}
            ;;
        esac
        ;;
    esac
  done
  ((checkout)) || host "${args[@]}"
  if [[ -z $dest ]]; then
    dest=$source
    while [[ $dest == */ ]]; do
      dest=${dest%/}
    done
    dest=${dest%/.git}
    dest=${dest%.git}
    dest=${dest##*[/:]}
    [[ -n $dest ]] || fail "clone needs a destination directory"
    if ((ended)); then
      args+=("$dest")
    else
      args+=(-- "$dest")
    fi
  fi
  host_run clone --no-checkout "${args[@]:1}" || exit
  [[ $dest == /* ]] || dest=$cwd/$dest
  checkout_in "$dest"
}

# Check out HEAD in a work tree the host just created without a checkout.
checkout_in() {
  local keep=() i
  for ((i = 0; i < ${#globals[@]}; i++)); do
    if [[ ${globals[i]} == -c ]]; then
      keep+=(-c "${globals[i + 1]}")
      i=$((i + 1))
    fi
  done
  globals=("${keep[@]}")
  cwd=$1
  cd -- "$cwd" || exit
  if host_run rev-parse --verify --quiet HEAD >/dev/null; then
    jail checkout --quiet --force HEAD
  fi
}

# Git also names a worktree by the last components of its path.
worktree_path() {
  local arg=$1 line found=()
  [[ $arg == /* ]] || arg=$cwd/$arg
  if [[ -e $arg ]]; then
    printf '%s' "$arg"
    return
  fi
  while IFS= read -r -d '' line; do
    [[ $line == "worktree "* ]] || continue
    line=${line#worktree }
    [[ $line == "$arg" || $line == */"$1" ]] && found+=("$line")
  done < <(host_run worktree list --porcelain -z)
  ((${#found[@]} == 1)) || fail "no worktree named $1"
  printf '%s' "${found[0]}"
}

worktree() {
  local i arg path='' args=() ended=0 checkout=1 lock=0 status
  case ${2:-} in
    # The jail would show every worktree outside the repository as prunable. List only reads
    # the administrative files and prints what they say.
    list) host "$@" ;;
    # Prune can't tell a moved or half-made worktree, hidden by the jail, from a deleted one, and
    # on the host it deletes inside whatever an entry under worktrees/ links to.
    prune) skip "worktree prune" ;;
    add)
      for ((i = 3; i <= $#; i++)); do
        arg=${!i}
        if ((!ended)); then
          case $arg in
            --no-checkout)
              checkout=0
              continue
              ;;
            --checkout) continue ;;
            --lock) lock=1 ;;
            -b | -B | --reason)
              i=$((i + 1))
              args+=("$arg" "${!i}")
              continue
              ;;
            --) ended=1 ;;
          esac
          if [[ $arg == -* ]]; then
            args+=("$arg")
            continue
          fi
        fi
        args+=("$arg")
        [[ -n $path ]] || path=$arg
      done
      ((checkout)) || host "$@"
      [[ -n $path ]] || fail "worktree add needs a path"
      # Locked like Git's own add until the checkout is done.
      ((lock)) || args=(--lock --reason initializing "${args[@]}")
      host_run worktree add --no-checkout "${args[@]}" || exit
      [[ $path == /* ]] || path=$cwd/$path
      path=$(physical "$path") || fail "no such directory: $path"
      (checkout_in "$path")
      status=$?
      ((lock)) || (jail worktree unlock -- "$path") || exit
      exit "$status"
      ;;
    remove | move | lock | unlock)
      local first=1
      for ((i = 3; i <= $#; i++)); do
        [[ ${!i} == -- ]] && ended=1 && continue
        if ((!ended)) && [[ ${!i} == --reason ]]; then
          i=$((i + 1))
          continue
        fi
        [[ $ended == 0 && ${!i} == -* ]] && continue
        if ((first)); then
          path=$(worktree_path "${!i}") || exit
          bind_parent "$path"
          first=0
        else
          bind_parent "${!i}"
        fi
      done
      ;;
    # Repair writes a .git file into each worktree it finds, so only the ones named are exposed.
    repair)
      for ((i = 3; i <= $#; i++)); do
        [[ ${!i} == -- ]] && ended=1 && continue
        [[ $ended == 0 && ${!i} == -* ]] && continue
        arg=${!i}
        [[ $arg == /* ]] || arg=$cwd/$arg
        path=$(physical "$arg") || fail "no such directory: ${!i}"
        extra+=("$path")
      done
      ;;
  esac
  jail "$@"
}

skip() {
  echo "orca-host-git: skipped $1; run it by hand on the host" >&2
  exit 0
}

# Init from outside the new repository runs from inside it, so the jail exposes it.
init() {
  local i arg opts=() dir='' ended=0
  for ((i = 2; i <= $#; i++)); do
    arg=${!i}
    if ((!ended)); then
      case $arg in
        --) ended=1 && continue ;;
        --separate-git-dir | --separate-git-dir=*) fail "init --separate-git-dir isn't supported" ;;
        --template)
          i=$((i + 1))
          arg=--template=${!i}
          ;;&
        --template=?*)
          [[ $arg == --template=/* ]] || arg=--template=$cwd/${arg#--template=}
          opts+=("$arg")
          continue
          ;;
        -b | --initial-branch | --object-format | --ref-format)
          i=$((i + 1))
          opts+=("$arg" "${!i}")
          continue
          ;;
        -*)
          opts+=("$arg")
          continue
          ;;
      esac
    fi
    [[ -z $dir ]] || fail "init takes one directory"
    dir=$arg
  done
  if [[ -n $dir ]]; then
    [[ $dir == /* ]] || dir=$cwd/$dir
    mkdir -p -- "$dir" || exit 128
    cwd=$dir
  fi
  cwd=$(physical "$cwd") || fail "no such directory: $cwd"
  guarded_path "$cwd" && fail "won't initialize a repository in $cwd"
  jail init "${opts[@]}"
}

# The fetch that add -f starts needs the network.
remote() {
  local i arg args=() name="" fetching=0
  [[ ${2:-} == add ]] || jail "$@"
  for ((i = 3; i <= $#; i++)); do
    arg=${!i}
    case $arg in
      -f | --fetch) fetching=1 ;;
      --no-fetch) fetching=0 ;;
      -t | --track | -m | --master)
        i=$((i + 1))
        args+=("$arg" "${!i}")
        ;;
      -*) args+=("$arg") ;;
      *)
        [[ -n $name ]] || name=$arg
        args+=("$arg")
        ;;
    esac
  done
  ((fetching)) || jail "$@"
  (jail remote add "${args[@]}") || exit
  host fetch -- "$name"
}

# Help runs man.<tool>.cmd, browser.<tool>.cmd and the like from repository config.
for arg in "${@:2}"; do
  [[ $arg == -- ]] && break
  case $arg in
    --hel* | --man | --web | --info) jail "$@" ;;
  esac
done

# The host only runs what needs the network or the credential helpers, and worktree list. None of
# these commands reads attributes, runs a diff driver or textconv, or formats commits; pagers,
# editors, hooks, housekeeping and transports are pinned above.
case $sub in
  push)
    for arg in "${@:2}"; do
      [[ $arg == -- ]] && break
      if [[ $arg == --no-veri* && --no-verify == "$arg"* ]]; then
        fail "push --no-verify would skip the Betterleaks secret scan"
      fi
    done
    push "$@"
    ;;
  fetch | ls-remote | credential | version | --version | -v | '') host "$@" ;;
  remote)
    for arg in "${@:2}"; do
      case $arg in
        update | prune | show | set-head) host "$@" ;;
        -*) ;;
        *) break ;;
      esac
    done
    remote "$@"
    ;;
  worktree) worktree "$@" ;;
  # A diff driver's command and diff.external would replace the output Orca parses.
  diff | log | show) jail "$1" --no-ext-diff "${@:2}" ;;
  pull) pull "$@" ;;
  clone) clone "$@" ;;
  init) init "$@" ;;
  # Both prune worktrees, and Orca runs neither.
  gc | maintenance) skip "$1" ;;
  *) jail "$@" ;;
esac
