# shellcheck shell=bash
usage() {
  cat <<'USAGE'
Usage: git-repo-guard <repository>

Exit 0 when the repository's own Git state runs nothing: <repository>/.git is
a directory without a commondir redirect, its config sets only allowlisted
keys (no include, extension, hook, filter, helper, program or command), its
remotes use https, ssh or scp-style URLs, and its hooks directory holds only
the *.sample files git init writes. Otherwise print each problem and exit 1.
Exit 2 on usage errors. The config is parsed, never evaluated.
USAGE
}

case ${1:-} in
  -h | --help)
    usage
    exit 0
    ;;
  '' | -*)
    usage >&2
    exit 2
    ;;
esac
[[ $# == 1 ]] || {
  usage >&2
  exit 2
}

git_dir=$1/.git
problems=()
problem() { problems+=("$*"); }

if [[ -L $git_dir || ! -d $git_dir ]]; then
  echo "git-repo-guard: $git_dir is not a plain directory" >&2
  exit 1
fi
[[ -e $git_dir/commondir || -L $git_dir/commondir ]] && problem "$git_dir/commondir redirects the repository"
[[ -L $git_dir/config ]] && problem "$git_dir/config is a symlink"

allowed='^(core\.(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode|symlinks)'
allowed+='|remote\.[^.]+\.(url|pushurl|fetch|tagopt|prune)'
allowed+='|branch\..+\.(remote|merge|base|rebase)'
allowed+='|push\.(autosetupremote|default)|user\.(name|email))$'
if [[ -f $git_dir/config && ! -L $git_dir/config ]]; then
  if ! entries=$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git config --file "$git_dir/config" --no-includes --list -z 2>&1 | tr '\0' '\036'); then
    problem "$git_dir/config does not parse: ${entries//$'\036'/ }"
  else
    while IFS= read -r -d $'\036' entry; do
      key=${entry%%$'\n'*}
      value=${entry#*$'\n'}
      [[ $entry == *$'\n'* ]] || value=
      if [[ ! $key =~ $allowed ]]; then
        problem "$git_dir/config sets $key"
      elif [[ $key =~ ^remote\..+\.(push)?url$ && ! $value =~ ^(https://|ssh://|[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:)[^[:space:]]+$ ]]; then
        problem "$git_dir/config sets $key to an unexpected kind of URL"
      fi
    done <<<"$entries"
  fi
fi

if [[ -L $git_dir/hooks ]]; then
  problem "$git_dir/hooks is a symlink"
elif [[ -d $git_dir/hooks ]]; then
  for hook in "$git_dir"/hooks/* "$git_dir"/hooks/.[!.]*; do
    [[ -e $hook || -L $hook ]] || continue
    if [[ $hook != *.sample || -L $hook || ! -f $hook ]]; then
      problem "$hook is a hook"
    fi
  done
fi

if ((${#problems[@]})); then
  printf 'git-repo-guard: %s\n' "${problems[@]}" >&2
  exit 1
fi
