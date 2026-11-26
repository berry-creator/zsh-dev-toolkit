#!/usr/bin/env zsh

_subrepo_script_dir="${${(%):-%N}:A:h}"
. "${_subrepo_script_dir}/logging.zsh"
unset _subrepo_script_dir

subrepo_help() {
  cat <<'HELP'
Usage: subrepo.zsh <command> [arguments...]
       . /path/to/subrepo.zsh

Generic operations on ordinary Git clones. All paths, refs and sparse rules
are supplied by the caller; this module does not read project configuration.

  clone <url> <directory> <branch|tag|commit> <value> [full|cone|no-cone] [file|-]
  fetch <directory> [remote]
  resolve <directory> <branch|tag|commit> <value> [remote]
  checkout <directory> <branch|tag|commit> <value> [force:no|yes] [remote]
  update-current <directory>
  switch-candidates <directory> <branch> [...]
  apply-sparse-file <directory> <full|cone|no-cone> [file|-]
  require-repository <directory> [expected-url]
  require-clean <directory>
  require-removable <directory> [remote]
  guard-path <root> <relative-path> [allow-leaf-link:no|yes]
  status <directory>
  remove <directory>
  -h, --help

Sparse patterns are read from the supplied file or stdin. Repository operations
reject symbolic links in the checkout path and its parents. Checkout preserves
local changes/branch commits unless force=yes is explicitly requested.
HELP
}

_subrepo_arguments() {
  if (( $4 < $2 || $4 > $3 )); then
    log_error "Usage: $1 $5"
    return 1
  fi
}

subrepo_validate_relative_path() {
  _subrepo_arguments subrepo_validate_relative_path 1 1 "$#" '<relative-path>' || return 1
  local value="$1" part
  [[ -n "$value" && "$value" != /* && "$value" != */ && "$value" != *$'\n'* && "$value" != *$'\t'* ]] || return 1
  for part in "${(@s:/:)value}"; do
    [[ -n "$part" && "$part" != . && "$part" != .. && "$part" != .git ]] || return 1
  done
}

# Print the first symbolic link without resolving or entering its target.
subrepo_symlink_path() {
  _subrepo_arguments subrepo_symlink_path 2 3 "$#" '<root> <relative-path> [allow-leaf-link:no|yes]' || return 1
  local root="${1:a}" relative="$2" allow_leaf="${3:-no}" current part
  current="${root%/}"
  for part in "${(@s:/:)relative}"; do
    current="$current/$part"
    if [[ -L "$current" ]] && ! [[ "$allow_leaf" == yes && "$current" == "${root%/}/$relative" ]]; then
      print -r -- "$current"
      return 0
    fi
  done
  return 1
}

subrepo_guard_path() {
  _subrepo_arguments subrepo_guard_path 2 3 "$#" '<root> <relative-path> [allow-leaf-link:no|yes]' || return 1
  local blocker
  subrepo_validate_relative_path "$2" || { log_error "Invalid relative path: $2"; return 1; }
  if blocker="$(subrepo_symlink_path "$@")"; then
    log_error "Symbolic link blocks operation: $blocker -> $(readlink -- "$blocker"). Run operations in the owning repository."
    return 1
  fi
}

subrepo_require_repository() {
  _subrepo_arguments subrepo_require_repository 1 2 "$#" '<directory> [expected-url]' || return 1
  local directory="${1:a}" expected="${2:-}" top actual
  subrepo_guard_path / "${directory#/}" || return 1
  [[ -d "$directory/.git" && ! -L "$directory/.git" ]] || {
    log_error "Not an ordinary clone: $directory (migrate legacy submodules first)"
    return 1
  }
  top="$(git -C "$directory" rev-parse --show-toplevel)" || return 1
  [[ "${top:A}" == "${directory:A}" ]] || return 1
  if [[ -n "$expected" ]]; then
    actual="$(git -C "$directory" config --local --get remote.origin.url)" || return 1
    [[ "${actual%.git}" == "${expected%.git}" ]] || { log_error "Origin mismatch: $directory; preserve the existing repository"; return 1; }
  fi
}

subrepo_require_idle() {
  local directory="$1" gitdir marker
  subrepo_require_repository "$directory" || return 1
  gitdir="$(git -C "$directory" rev-parse --absolute-git-dir)" || return 1
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer BISECT_LOG; do
    [[ ! -e "$gitdir/$marker" ]] || { log_error "Git operation in progress: $directory"; return 1; }
  done
}

subrepo_require_clean() {
  _subrepo_arguments subrepo_require_clean 1 1 "$#" '<directory>' || return 1
  local directory="$1" changes entry flag relative
  subrepo_require_idle "$directory" || return 1
  changes="$(git -C "$directory" status --porcelain --untracked-files=all)" || return 1
  [[ -z "$changes" ]] || {
    log_error "Local changes: $directory; commit, stash or discard them first"
    return 1
  }
  # Index flags can hide modified files from an otherwise clean status.
  while IFS= read -r -d '' entry; do
    flag="${entry[1]}"; relative="${entry[3,-1]}"
    if [[ "$flag" == [a-z] ]] || { [[ "$flag" == S ]] && [[ -e "$directory/$relative" || -L "$directory/$relative" ]]; }; then
      log_error "Hidden index state prevents operation: $relative"
      return 1
    fi
  done < <(git -C "$directory" ls-files -v -z)
}

# Preserve detached commits that would otherwise lose their last reference.
subrepo_require_preserved_head() {
  local directory="$1" refs
  if ! git -C "$directory" symbolic-ref --quiet HEAD >/dev/null; then
    refs="$(git -C "$directory" for-each-ref --contains=HEAD --format='%(refname)' refs/heads refs/tags refs/remotes)" || return 1
    [[ -n "$refs" ]] || { log_error "Unreferenced detached HEAD: $directory"; return 1; }
  fi
}

# Verify recoverability from fresh remote refs without changing local branches,
# tags or remote-tracking refs. Unknown local state is never deleted implicitly.
subrepo_require_removable() (
  _subrepo_arguments subrepo_require_removable 1 2 "$#" '<directory> [remote]' || return 1
  local directory="${1:a}" remote="${2:-origin}" gitdir temporary namespace refs before head ref oid remote_oid missing nested state_before entry relative
  subrepo_require_clean "$directory" || return 1
  [[ -z "$(git -C "$directory" ls-files --others --ignored --exclude-standard)" ]] || {
    log_error "Ignored local files prevent removal: $directory"; return 1
  }
  [[ -z "$(git -C "$directory" for-each-ref --format='%(refname)' refs/stash)" ]] || {
    log_error "Local stash prevents removal: $directory"; return 1
  }
  [[ "$(git -C "$directory" worktree list --porcelain | awk '/^worktree / { count++ } END { print count+0 }')" == 1 ]] || {
    log_error "Other worktrees depend on this clone: $directory"; return 1
  }
  nested="$(find "$directory" -path "$directory/.git" -prune -o -name .git -print -prune)" || return 1
  [[ -z "$nested" ]] || { log_error "Nested Git repository prevents removal: $directory"; return 1; }
  # Uninitialized gitlinks may contain files hidden by submodule ignore rules.
  while IFS= read -r -d '' entry; do
    [[ "$entry" == '160000 '* ]] || continue
    relative="${entry#*$'\t'}"
    if [[ -d "$directory/$relative" && -n "$(find "$directory/$relative" -mindepth 1 -print -quit)" ]]; then
      log_error "Populated gitlink prevents removal: $relative"
      return 1
    fi
  done < <(git -C "$directory" ls-files --stage -z)
  refs="$(git -C "$directory" for-each-ref --format='%(refname)')" || return 1
  for ref in "${(@f)refs}"; do
    case "$ref" in
      refs/heads/*|refs/tags/*|refs/remotes/*|refs/subrepo-check/*) ;;
      *) log_error "Unpublished local ref prevents removal: $ref"; return 1 ;;
    esac
  done
  before="$(git -C "$directory" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags)" || return 1
  state_before="$(git -C "$directory" for-each-ref --format='%(refname) %(objectname)' | awk '$1 !~ /^refs\/subrepo-check\//')" || return 1
  head="$(git -C "$directory" rev-parse HEAD)" || return 1
  gitdir="$(git -C "$directory" rev-parse --absolute-git-dir)" || return 1
  temporary="$(mktemp -d "$gitdir/subrepo-check.XXXXXX")" || return 1
  namespace="refs/subrepo-check/${temporary:t}"
  trap 'git -C "$directory" for-each-ref --format="delete %(refname)" "$namespace/" | git -C "$directory" update-ref --stdin; rmdir "$temporary"' EXIT
  if ! git -C "$directory" -c fetch.recurseSubmodules=false fetch --no-prune --no-prune-tags --no-tags --no-write-fetch-head --refmap= -- "$remote" "+refs/heads/*:$namespace/heads/*" "+refs/tags/*:$namespace/tags/*"; then
    log_error "Cannot verify remote state; removal refused: $directory"; return 1
  fi
  [[ -n "$(git -C "$directory" for-each-ref --format='%(refname)' "$namespace/")" ]] || {
    log_error "No remote refs prove recoverability: $directory"; return 1
  }
  while read -r ref oid; do
    [[ -n "$ref" ]] || continue
    remote_oid="$(git -C "$directory" rev-parse --verify "$namespace/${ref#refs/}" 2>/dev/null)" || {
      log_error "Unpublished local ref prevents removal: $ref"; return 1
    }
    if [[ "$ref" == refs/tags/* ]]; then
      [[ "$oid" == "$remote_oid" ]] || { log_error "Local tag differs from remote: $ref"; return 1; }
    elif ! git -C "$directory" merge-base --is-ancestor "$oid" "$remote_oid"; then
      log_error "Unpushed or divergent branch prevents removal: $ref"; return 1
    fi
  done <<< "$before"
  missing="$(git -C "$directory" rev-list --max-count=1 HEAD --branches --not --glob="$namespace/*")" || return 1
  [[ -z "$missing" ]] || { log_error "Local commits are absent from the remote: $directory"; return 1; }
  subrepo_require_clean "$directory" || return 1
  [[ -z "$(git -C "$directory" ls-files --others --ignored --exclude-standard)" &&
     -z "$(git -C "$directory" for-each-ref --format='%(refname)' refs/stash)" &&
     "$(git -C "$directory" rev-parse HEAD)" == "$head" &&
     "$(git -C "$directory" for-each-ref --format='%(refname) %(objectname)' | awk '$1 !~ /^refs\/subrepo-check\//')" == "$state_before" ]] || {
    log_error "Repository changed during removal checks: $directory"; return 1
  }
)

subrepo_validate_ref() {
  _subrepo_arguments subrepo_validate_ref 2 2 "$#" '<branch|tag|commit> <value>' || return 1
  case "$1" in
    branch) [[ -n "$2" && "$2" != -* && "$2" != HEAD ]] && git check-ref-format "refs/heads/$2" >/dev/null 2>&1 ;;
    tag) git check-ref-format "refs/tags/$2" >/dev/null 2>&1 ;;
    commit) [[ "$2" =~ '^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$' ]] ;;
    *) return 1 ;;
  esac
}

subrepo_fetch() {
  _subrepo_arguments subrepo_fetch 1 2 "$#" '<directory> [remote]' || return 1
  local directory="$1" remote="${2:-origin}"
  subrepo_require_repository "$directory" || return 1
  git -C "$directory" -c fetch.recurseSubmodules=false fetch --prune --tags -- "$remote" "+refs/heads/*:refs/remotes/$remote/*"
}

# Resolve the exact ref, fetching a requested commit only when it is absent.
subrepo_resolve() {
  _subrepo_arguments subrepo_resolve 3 4 "$#" '<directory> <branch|tag|commit> <value> [remote]' || return 1
  local directory="$1" kind="$2" value="$3" remote="${4:-origin}" ref commit
  subrepo_require_repository "$directory" && subrepo_validate_ref "$kind" "$value" || return 1
  case "$kind" in
    branch) ref="refs/remotes/$remote/$value" ;;
    tag) ref="refs/tags/$value" ;;
    commit) ref="$value" ;;
  esac
  if [[ "$kind" == commit ]] && ! git -C "$directory" cat-file -e "$ref^{commit}" 2>/dev/null; then
    git -C "$directory" -c fetch.recurseSubmodules=false fetch --no-tags -- "$remote" "$ref" || return 1
  fi
  commit="$(git -C "$directory" rev-parse --verify --end-of-options "$ref^{commit}" 2>/dev/null)" || {
    log_error "Missing exact $kind=$value in $directory; no fallback"
    return 1
  }
  print -r -- "$commit"
}

subrepo_checkout() {
  _subrepo_arguments subrepo_checkout 3 5 "$#" '<directory> <branch|tag|commit> <value> [force:no|yes] [remote]' || return 1
  local directory="$1" kind="$2" value="$3" force="${4:-no}" remote="${5:-origin}" commit
  [[ "$force" == no || "$force" == yes ]] || return 1
  subrepo_require_repository "$directory" || return 1
  subrepo_require_idle "$directory" || return 1
  [[ "$force" == yes ]] || subrepo_require_clean "$directory" || return 1
  [[ "$force" == yes ]] || subrepo_require_preserved_head "$directory" || return 1
  commit="$(subrepo_resolve "$directory" "$kind" "$value" "$remote")" || return 1
  if [[ "$force" == yes ]]; then
    git -C "$directory" reset --hard HEAD || return 1
  fi
  if [[ "$kind" == branch ]]; then
    if git -C "$directory" show-ref --verify --quiet "refs/heads/$value"; then
      if [[ "$force" != yes ]] && ! git -C "$directory" merge-base --is-ancestor "refs/heads/$value" "$commit"; then
        log_error "Local branch $value has commits absent from $remote; refusing to overwrite"
        return 1
      fi
      git -C "$directory" switch -- "$value" || return 1
      if [[ "$force" == yes ]]; then
        git -C "$directory" reset --hard "$commit" || return 1
      else
        git -C "$directory" merge --ff-only "$commit" || return 1
      fi
    else
      git -C "$directory" switch --no-track -c "$value" "$commit" || return 1
    fi
    git -C "$directory" branch --set-upstream-to="$remote/$value" "$value" >/dev/null
  else
    git -C "$directory" switch --detach "$commit"
  fi
}

# Exit 3 denotes a protected checkout, rather than a transport/configuration error.
subrepo_update_current() {
  _subrepo_arguments subrepo_update_current 1 1 "$#" '<directory>' || return 1
  local directory="$1" branch head remote merge commit
  subrepo_require_clean "$directory" || return 3
  branch="$(git -C "$directory" symbolic-ref --quiet HEAD)" || {
    log_error 'Detached HEAD is protected; select a branch explicitly'; return 3
  }
  branch="${branch#refs/heads/}"
  head="$(git -C "$directory" rev-parse HEAD)" || return 1
  remote="$(git -C "$directory" config --get "branch.$branch.remote" || true)"
  merge="$(git -C "$directory" config --get "branch.$branch.merge" || true)"
  [[ -n "$remote$merge" ]] || { remote=origin; merge="refs/heads/$branch"; }
  [[ -n "$remote" && "$remote" != . && "$merge" == refs/heads/* && "$remote$merge" != *$'\n'* ]] || {
    log_error 'Invalid branch upstream'; return 3
  }
  git -C "$directory" -c fetch.recurseSubmodules=false fetch --prune --no-tags -- "$remote" "+refs/heads/*:refs/remotes/$remote/*" || return 1
  commit="$(git -C "$directory" rev-parse --verify "refs/remotes/$remote/${merge#refs/heads/}^{commit}" 2>/dev/null)" || {
    log_error 'Upstream branch is missing'; return 3
  }
  git -C "$directory" merge-base --is-ancestor "$head" "$commit" || {
    log_error 'Local branch is ahead or divergent'; return 3
  }
  [[ "$(git -C "$directory" rev-parse HEAD)" == "$head" && "$(git -C "$directory" symbolic-ref --quiet HEAD)" == "refs/heads/$branch" ]] || return 3
  subrepo_require_clean "$directory" || return 3
  git -C "$directory" merge --ff-only "$commit"
}

# Print only the selected branch to stdout; exit 4 means no candidate exists.
subrepo_switch_candidates() {
  (( $# >= 2 )) || { log_error 'Usage: subrepo_switch_candidates <directory> <branch> [...]'; return 1; }
  local directory="$1" branch
  shift
  subrepo_require_clean "$directory" || return 3
  for branch in "$@"; do subrepo_validate_ref branch "$branch" || return 1; done
  git -C "$directory" -c fetch.recurseSubmodules=false fetch --prune --no-tags origin '+refs/heads/*:refs/remotes/origin/*' || return 1
  subrepo_require_preserved_head "$directory" || return 3
  for branch in "$@"; do
    if git -C "$directory" show-ref --verify --quiet "refs/heads/$branch"; then
      subrepo_require_clean "$directory" || return 3
      git -C "$directory" switch --no-guess -- "$branch" >&2 || return 1
    elif git -C "$directory" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      subrepo_require_clean "$directory" || return 3
      git -C "$directory" switch --no-track -c "$branch" "refs/remotes/origin/$branch" >&2 || return 1
      git -C "$directory" branch --set-upstream-to="origin/$branch" "$branch" >&2 || return 1
    else
      continue
    fi
    print -r -- "$branch"
    return 0
  done
  log_error 'No candidate branch exists; checkout preserved'
  return 4
}

subrepo_apply_sparse_file() {
  _subrepo_arguments subrepo_apply_sparse_file 2 3 "$#" '<directory> <full|cone|no-cone> [file|-]' || return 1
  local directory="$1" mode="$2" patterns="${3:--}"
  subrepo_require_repository "$directory" || return 1
  case "$mode" in
    full) git -C "$directory" sparse-checkout disable ;;
    cone|no-cone)
      if [[ "$patterns" == - ]]; then
        git -C "$directory" sparse-checkout set "--$mode" --stdin
      else
        [[ -f "$patterns" ]] || { log_error "Sparse patterns file not found: $patterns"; return 1; }
        git -C "$directory" sparse-checkout set "--$mode" --stdin < "$patterns"
      fi
      ;;
    *) log_error "Invalid sparse mode: $mode"; return 1 ;;
  esac
}

subrepo_clone() (
  _subrepo_arguments subrepo_clone 4 6 "$#" '<url> <directory> <branch|tag|commit> <value> [full|cone|no-cone] [file|-]' || return 1
  local url="$1" directory="${2:a}" kind="$3" value="$4" mode="${5:-full}" patterns="${6:--}" staging
  subrepo_guard_path / "${directory#/}" && subrepo_validate_ref "$kind" "$value" || return 1
  [[ ! -e "$directory" ]] || { log_error "Clone destination already exists: $directory"; return 1; }
  mkdir -p -- "${directory:h}" || return 1
  staging="$(mktemp -d "${directory:h}/.subrepo-checkout.XXXXXX")" || return 1
  trap 'rm -rf -- "$staging"' EXIT
  git -c submodule.recurse=false clone --filter=blob:none --no-checkout -- "$url" "$staging" || return 1
  # A no-checkout clone has no populated index; initialize only this new staging tree.
  subrepo_fetch "$staging" && subrepo_apply_sparse_file "$staging" "$mode" "$patterns" &&
    subrepo_checkout "$staging" "$kind" "$value" yes || return 1
  [[ ! -e "$directory" && ! -L "$directory" ]] || return 1
  mv -T -- "$staging" "$directory"
)

subrepo_status() {
  _subrepo_arguments subrepo_status 1 1 "$#" '<directory>' || return 1
  subrepo_require_repository "$1" || return 1
  git -C "$1" log -1 --format='HEAD=%H %s' && git -C "$1" status --short --branch
}

subrepo_remove() {
  _subrepo_arguments subrepo_remove 1 1 "$#" '<directory>' || return 1
  subrepo_require_removable "$1" || return 1
  rm -rf -- "${1:a}"
}

_subrepo_main() {
  local command="${1:---help}"
  (( $# == 0 )) || shift
  case "$command" in
    clone) subrepo_clone "$@" ;;
    fetch) subrepo_fetch "$@" ;;
    resolve) subrepo_resolve "$@" ;;
    checkout) subrepo_checkout "$@" ;;
    update-current) subrepo_update_current "$@" ;;
    switch-candidates) subrepo_switch_candidates "$@" ;;
    apply-sparse-file) subrepo_apply_sparse_file "$@" ;;
    require-repository) subrepo_require_repository "$@" ;;
    require-clean) subrepo_require_clean "$@" ;;
    require-removable) subrepo_require_removable "$@" ;;
    guard-path) subrepo_guard_path "$@" ;;
    status) subrepo_status "$@" ;;
    remove) subrepo_remove "$@" ;;
    -h|--help) subrepo_help ;;
    *) log_error "Unknown subrepo command: $command"; subrepo_help >&2; return 1 ;;
  esac
}

if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then
  _subrepo_main "$@"
fi
