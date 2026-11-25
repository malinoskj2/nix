usage() {
  cat <<'USAGE'
Usage: worktree-closeout [--into <ref>] [--delete-branch] [--dry-run] <worktree>

Close out a finished Orca worktree. <worktree> is an Orca selector (path:, name:,
branch:, id:...) or a path. Its HEAD must be merged into <ref>, by default its
parent worktree's branch or else the main checkout's branch, and it must have no
tracked changes. Its .tmp/ and untracked files are copied, never overwriting,
into the main checkout's .tmp/<worktree-name>/ (untracked files under
untracked/), then the worktree is removed with orca worktree rm, forced only
when untracked files would block it.
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

# Copy without overwriting, then require every source file to match what is there.
preserve() {
  local src=$1 target=$2 rel file
  mkdir -p "$target"
  cp -a --reflink=auto --update=none -- "$src" "$target/"
  while IFS= read -r -d '' file; do
    rel=${file#"$src"}
    if [[ -L $file ]]; then
      [[ -L $target/${src##*/}$rel && $(readlink -- "$file") == $(readlink -- "$target/${src##*/}$rel") ]]
    else
      cmp -s -- "$file" "$target/${src##*/}$rel"
    fi || die "$target/${src##*/}$rel already exists and differs; nothing was removed"
  done < <(find "$src" \( -type f -o -type l \) -print0)
}

if [[ -n $dry_run ]]; then
  echo "worktree: $path ($id)"
  echo "merged into: $into"
  [[ -d $path/.tmp ]] && echo "would copy: $path/.tmp/ -> $dest/"
  for file in "${untracked[@]}"; do
    echo "would copy: $path/$file -> $dest/untracked/$file"
  done
  exit 0
fi

shopt -s dotglob nullglob
reports=("$path"/.tmp/*)
for entry in "${reports[@]}"; do
  preserve "$entry" "$dest"
done
((${#reports[@]})) && echo "copied $path/.tmp/ to $dest/"
for file in "${untracked[@]}"; do
  dir=$(dirname -- "$file")
  preserve "$path/$file" "$dest/untracked/$dir"
  echo "copied $file to $dest/untracked/$file"
done

rm_args=(worktree rm --worktree "id:$id" --json)
((${#untracked[@]})) && rm_args+=(--force)
[[ -n $delete_branch ]] && rm_args+=(--delete-branch)
"$orca" "${rm_args[@]}" >/dev/null || die "orca worktree rm failed; the copies in $dest remain"
echo "removed $path"
