# shellcheck shell=bash
usage() {
  cat <<'USAGE'
Usage: worktree-closeout [--into <ref>] [--delete-branch] [--dry-run] <worktree>

Close out a finished Orca worktree. <worktree> is an Orca selector (path:, name:,
branch:, id:...) or a path. Its HEAD must be merged into <ref>, by default its
parent worktree's branch or else the main checkout's branch, and it must have no
tracked changes. Its .tmp/ and untracked files are copied, never overwriting,
into the main checkout's .tmp/<worktree-name>/ (untracked files under
untracked/), except build outputs (directories with a valid CACHEDIR.TAG such
as Cargo targets, virtualenvs, node_modules, bytecode-only __pycache__), which
are deleted. Then the worktree is
removed with orca worktree rm, forced only when untracked files would block it.
USAGE
}

die() {
  echo "worktree-closeout: $*" >&2
  exit 1
}

orca=${ORCA_CLI_COMMAND:-orca-ide}
into='' delete_branch='' dry_run='' selector=''
while (($#)); do
  case $1 in
    --into)
      (($# >= 2)) || die "--into needs a ref"
      into=$2
      shift 2
      ;;
    --delete-branch)
      delete_branch=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option $1" ;;
    *)
      [[ -z $selector ]] || die "only one worktree at a time"
      selector=$1
      shift
      ;;
  esac
done
[[ -n $selector ]] || {
  usage >&2
  exit 2
}
if [[ $selector != *:* ]]; then
  selector=path:$(realpath -e -- "$selector") || die "no such worktree path"
fi

show() {
  "$orca" worktree show --worktree "$1" --json | jq -e '.result.worktree'
}
info=$(show "$selector") || die "Orca doesn't know worktree $selector"
id=$(jq -r .id <<<"$info")
path=$(jq -r .path <<<"$info")
name=$(jq -r '.displayName // empty' <<<"$info")
name=${name:-${path##*/}}
parent_id=$(jq -r '.parentWorktreeId // empty' <<<"$info")

[[ $(jq -r .isMainWorktree <<<"$info") != true ]] || die "$path is a main checkout"
[[ -d $path ]] || die "$path is missing"
git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$path is not a Git worktree"
case $PWD/ in "$path"/*) die "run this from outside $path; removing it stops its sessions" ;; esac

common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)
main=$(git -C "$path" worktree list --porcelain | sed -n '1s/^worktree //p')
[[ -n $main && $common == "$main/.git" ]] || die "can't find the main checkout for $path"

if [[ -z $into ]]; then
  if [[ -n $parent_id ]]; then
    into=$(show "id:$parent_id" | jq -r '.branch // empty') || die "can't read parent worktree $parent_id"
  else
    into=$(git -C "$main" symbolic-ref -q HEAD) || die "main checkout $main has a detached HEAD; pass --into"
  fi
fi
into=${into#refs/heads/}
git -C "$path" rev-parse -q --verify "$into^{commit}" >/dev/null || die "no such ref $into"

# Rebased or cherry-picked merges leave equivalent patches rather than the same commits.
if ! git -C "$path" merge-base --is-ancestor HEAD "$into" &&
  git -C "$path" cherry "$into" HEAD | grep -q '^+'; then
  die "$path has commits that aren't in $into:"$'\n'"$(git -C "$path" log --oneline "$into..HEAD" | head -20)"
fi
dirty=$(git -C "$path" status --porcelain --untracked-files=no)
[[ -z $dirty ]] || die "$path has uncommitted changes:"$'\n'"$dirty"

mapfile -d '' untracked < <(git -C "$path" ls-files -z --others --exclude-standard)
dest=$main/.tmp/$name

# Build outputs are deleted with the worktree, never copied: directories with a
# valid CACHEDIR.TAG (Cargo targets), virtualenvs (pyvenv.cfg beside bin/python),
# node_modules beside a package.json, and __pycache__ holding only bytecode.
build_output() {
  local dir=$1
  case ${dir##*/} in
    node_modules) [[ -f ${dir%/*}/package.json ]] ;;
    __pycache__) [[ -z $(find "$dir" -type f ! -name '*.pyc' -print -quit) ]] ;;
    *)
      if [[ -f $dir/CACHEDIR.TAG ]]; then
        [[ $(head -c 43 -- "$dir/CACHEDIR.TAG") == 'Signature: 8a477f597d28d172789f06886806bc55' ]]
      else
        [[ -f $dir/pyvenv.cfg && -x $dir/bin/python ]] && grep -q '^home *=' -- "$dir/pyvenv.cfg"
      fi
      ;;
  esac
}
build_dirs=()
while IFS= read -r dir; do
  build_output "$dir" || continue
  [[ -n $(git -C "$path" ls-files -- "${dir#"$path"/}" | head -n 1) ]] || build_dirs+=("$dir")
done < <(
  find "$path" -name .git -prune -o \( -name node_modules -o -name __pycache__ \) -type d -prune -print -o \
    -type f \( -name CACHEDIR.TAG -o -name pyvenv.cfg \) -printf '%h\n' | sort -u
)
in_build_dir() {
  local dir
  for dir in "${build_dirs[@]}"; do
    [[ $1 == "$dir"/* ]] && return 0
  done
  return 1
}

sources=() targets=()
for file in "${untracked[@]}"; do
  if ! in_build_dir "$path/$file"; then
    sources+=("$path/$file")
    targets+=("$dest/untracked/$file")
  fi
done
if [[ -d $path/.tmp ]]; then
  while IFS= read -r -d '' file; do
    if ! in_build_dir "$file"; then
      sources+=("$file")
      targets+=("$dest/${file#"$path"/.tmp/}")
    fi
  done < <(find "$path/.tmp" \( -type f -o -type l \) -print0)
fi

# Copy without overwriting, then require the copy to match what is there.
preserve() {
  local src=$1 target=$2
  mkdir -p "$(dirname -- "$target")"
  cp -a --reflink=auto --update=none -- "$src" "$target"
  if [[ -L $src ]]; then
    [[ -L $target && $(readlink -- "$src") == $(readlink -- "$target") ]]
  else
    cmp -s -- "$src" "$target"
  fi || die "$target already exists and differs; nothing was removed"
}

if [[ -n $dry_run ]]; then
  echo "worktree: $path ($id)"
  echo "merged into: $into"
  for i in "${!sources[@]}"; do
    echo "would copy: ${sources[i]} -> ${targets[i]}"
  done
  for dir in "${build_dirs[@]}"; do
    echo "would delete build output: $dir ($(du -sh -- "$dir" | cut -f1))"
  done
  exit 0
fi

for i in "${!sources[@]}"; do
  preserve "${sources[i]}" "${targets[i]}"
done
((${#sources[@]} == 0)) || echo "copied ${#sources[@]} file(s) to $dest/"
for dir in "${build_dirs[@]}"; do
  [[ -d $dir ]] || continue
  size=$(du -sh -- "$dir" | cut -f1)
  rm -rf -- "$dir" && echo "deleted build output $dir ($size)"
done

rm_args=(worktree rm --worktree "id:$id" --json)
((${#untracked[@]})) && rm_args+=(--force)
[[ -n $delete_branch ]] && rm_args+=(--delete-branch)
"$orca" "${rm_args[@]}" >/dev/null || die "orca worktree rm failed; the copies in $dest remain"
echo "removed $path"
