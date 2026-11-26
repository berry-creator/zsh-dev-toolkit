#!/usr/bin/env zsh

_sync_remote_branches_dir="${${(%):-%N}:A:h}"
. "${_sync_remote_branches_dir}/logging.zsh"
. "${_sync_remote_branches_dir}/worktree.zsh"
unset _sync_remote_branches_dir

_sync_remote_branches_require_git_repo() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_error "Not inside a Git repository."
    return 1
  fi
}

_sync_remote_branches_require_git_remote() {
  local remote="$1"

  if [[ -z "${remote}" ]]; then
    log_error "Git remote is required."
    return 1
  fi

  if ! git remote get-url "${remote}" >/dev/null 2>&1; then
    log_error "Git remote not found: ${remote}"
    return 1
  fi
}

_sync_remote_branches_git_operation_in_progress() {
  [[ -d "$(git rev-parse --git-path rebase-merge)" ]] ||
    [[ -d "$(git rev-parse --git-path rebase-apply)" ]] ||
    [[ -f "$(git rev-parse --git-path MERGE_HEAD)" ]] ||
    [[ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]] ||
    [[ -f "$(git rev-parse --git-path REVERT_HEAD)" ]]
}

# Git refspecs allow a single wildcard; all other ref-name characters are literal.
_sync_remote_branches_match_refspec() {
  local pattern="$1" ref="$2" prefix suffix
  REPLY=""
  if [[ "${pattern}" != *\** ]]; then
    [[ "${ref}" == "${pattern}" ]]
    return $?
  fi

  prefix="${pattern%%\**}"
  suffix="${pattern#*\*}"
  [[ "${ref}" == "${prefix}"*"${suffix}" ]] || return 1
  (( ${#ref} >= ${#prefix} + ${#suffix} )) || return 1
  REPLY="${ref:${#prefix}:${#ref}-${#prefix}-${#suffix}}"
}

# Resolve a same-named source branch through the configured fetch mappings.
# Exit 2 means the source is excluded or has no persistent tracking destination.
_sync_remote_branches_tracking_ref() {
  local source="$1" spec mapping from to REPLY
  shift
  for spec in "$@"; do
    if [[ "${spec}" == '^'* ]] && _sync_remote_branches_match_refspec "${spec#\^}" "${source}"; then
      return 2
    fi
  done

  for spec in "$@"; do
    [[ "${spec}" != '^'* ]] || continue
    mapping="${spec#+}"
    [[ "${mapping}" == *:* ]] || continue
    from="${mapping%%:*}"
    to="${mapping#*:}"
    [[ -n "${to}" ]] || continue
    _sync_remote_branches_match_refspec "${from}" "${source}" || continue
    if [[ "${to}" == *\** ]]; then
      to="${to%%\**}${REPLY}${to#*\*}"
    fi
    [[ "${to}" == refs/remotes/* ]] || {
      log_error "Unsupported branch tracking destination: ${to}"
      return 1
    }
    print -r -- "${to}"
    return 0
  done
  return 2
}

_sync_remote_branches_usage() {
  cat <<'EOF'
Usage: sync_remote_branches [--rebase]

Synchronize local branches with same-named branches on origin.

Behavior:
  - Fetch and prune using origin's configured mappings, excluding tags.
  - Skip branches excluded by negative refspecs or absent from fetch mappings.
  - Resolve custom remote-tracking destinations instead of assuming origin/<name>.
  - Fast-forward local branches that are behind origin.
  - Keep local branches that are ahead of origin unchanged.
  - Skip diverged branches unless --rebase is specified.
  - Delete a local branch whose tracked origin branch was removed only when
    it is not main or the current branch and is already merged into local main.

Options:
  --rebase               Rebase diverged local branches onto origin branches
  -h, --help             Show this help

Notes:
  When started from a linked worktree, an interactive shell prompts before
  continuing from the main workspace. A non-interactive shell fails instead.
  --rebase requires a clean worktree and aborts a rebase when conflicts occur.
  An unborn HEAD is allowed; rebases requiring a switch back to it are skipped.
  Persistent fetch mappings require fully qualified refs/* sources. Non-tag
  mappings must target refs/remotes/*; unsupported mappings fail before fetching.
  Tags are managed separately by sync_remote_tags.
  Branches checked out in other worktrees are skipped when an update, delete,
  or rebase would modify them.
  This command can modify or delete local branches, but never pushes to origin.
EOF
}

# Synchronize local branches with same-named branches on origin.
#
# Usage: sync_remote_branches [--rebase]
# - Always uses origin and runs fetch --prune before comparing branches.
# - Uses configured tracking destinations and skips excluded or unmapped branches.
# - Fast-forwards local branches that are behind origin.
# - Reports local branches that are ahead of origin without modifying them.
# - Skips diverged branches by default. With --rebase, replays only genuine
#   local commits from the fork point onto the corresponding origin branch.
# - Requires a clean worktree in --rebase mode and aborts on conflicts.
# - Deletes a local branch whose tracked origin branch was removed only when
#   it is not main or the current branch and is already merged into local main.
# - Never pushes and therefore never modifies remote branches directly.
sync_remote_branches() {
  local remote="origin"
  local rebase=false
  local initial_branch_ref
  local current_branch
  local branch
  local fork_point
  local initial_head
  local local_ref
  local remote_ref
  local remote_label
  local upstream
  local advertised_heads remote_oid advertised_ref
  local branch_worktree_path
  local updated=0
  local rebased=0
  local ahead=0
  local deleted=0
  local skipped=0
  local unchanged=0
  local failed=0
  local branch_names
  local fetch_spec_text
  local spec mapping source destination result
  local -a branches
  local -a fetch_specs
  local -A remote_heads

  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _sync_remote_branches_usage
    return 0
  fi

  if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--rebase" ]]; }; then
    log_error "Usage: sync_remote_branches [--rebase]"
    _sync_remote_branches_usage >&2
    return 1
  fi

  if (( $# == 1 )); then
    rebase=true
  fi

  _sync_remote_branches_require_git_repo || return 1
  _sync_remote_branches_require_git_remote "${remote}" || return 1
  worktree_confirm_cd_main || return 1

  initial_branch_ref="$(git symbolic-ref --quiet HEAD)" || initial_branch_ref=""
  current_branch="${initial_branch_ref#refs/heads/}"
  # An unborn branch has a symbolic HEAD but no commit yet.
  initial_head="$(git rev-list -1 --ignore-missing HEAD --)" || return 1
  if [[ "${rebase}" == true ]]; then
    if [[ -z "${current_branch}" ]]; then
      log_error "Cannot rebase branches from detached HEAD."
      return 1
    fi

    if _sync_remote_branches_git_operation_in_progress; then
      log_error "Cannot rebase branches while another Git operation is in progress."
      return 1
    fi

    if [[ -n "$(git status --porcelain)" ]]; then
      log_error "Cannot rebase branches with uncommitted changes."
      return 1
    fi
  fi

  fetch_spec_text="$(git config --get-all "remote.${remote}.fetch")" || {
    log_error "No fetch mappings configured for ${remote}."
    return 1
  }
  fetch_specs=()
  for spec in "${(@f)fetch_spec_text}"; do
    mapping="${spec#+}"
    source="${mapping%%:*}"
    [[ "${source}" == refs/tags/* ]] && continue
    if [[ "${spec}" != '^'* && "${mapping}" == *:* ]]; then
      destination="${mapping#*:}"
      if [[ -n "${destination}" && "${source}" != refs/* ]]; then
        log_error "Unsupported fetch source: ${source}; expected a fully qualified ref."
        return 1
      fi
      if [[ -n "${destination}" && "${destination}" != refs/remotes/* ]]; then
        log_error "Unsupported fetch destination: ${destination}; expected refs/remotes/*."
        return 1
      fi
    fi
    fetch_specs+=("${spec}")
  done

  log_info "[fetch] ${remote} branches"
  git fetch --quiet --no-tags --no-prune-tags --prune --refmap= "${remote}" "${fetch_specs[@]}" '^refs/tags/*' || return 1

  # A tracking destination can also be populated from a PR or another namespace.
  # Index actual remote branch tips once for both updates and deletion checks.
  advertised_heads="$(git ls-remote --refs --heads "${remote}")" || return 1
  while IFS=$'\t' read -r remote_oid advertised_ref; do
    [[ -n "${advertised_ref}" ]] && remote_heads[${advertised_ref}]="${remote_oid}"
  done <<< "${advertised_heads}"

  # Fetch may run hooks or overlap with another Git client; recheck before writing.
  if [[ "$(git symbolic-ref --quiet HEAD)" != "${initial_branch_ref}" ||
        "$(git rev-list -1 --ignore-missing HEAD --)" != "${initial_head}" ]]; then
    log_error "HEAD changed during fetch; branch synchronization stopped."
    return 1
  fi
  if [[ "${rebase}" == true ]]; then
    if _sync_remote_branches_git_operation_in_progress ||
       [[ -n "$(git status --porcelain)" ]]; then
      log_error "Worktree changed during fetch; branch synchronization stopped."
      return 1
    fi
  fi

  branch_names="$(git for-each-ref --format='%(refname:strip=2)' refs/heads)" || return 1
  if [[ -z "${branch_names}" ]]; then
    log_done "[done] branches: updated 0, rebased 0, ahead 0, deleted 0, skipped 0, unchanged 0, failed 0"
    return 0
  fi

  branches=("${(@f)branch_names}")
  for branch in "${branches[@]}"; do
    local_ref="refs/heads/${branch}"
    remote_ref="$(_sync_remote_branches_tracking_ref "${local_ref}" "${fetch_specs[@]}")" || {
      result=$?
      (( result == 2 )) || return 1
      log_warn "[skip] ${branch} is excluded or has no tracking mapping on ${remote}"
      skipped=$((skipped + 1))
      continue
    }
    remote_label="${remote_ref#refs/remotes/}"
    remote_oid="${remote_heads[${local_ref}]:-}"

    if ! git show-ref --verify --quiet "${remote_ref}"; then
      upstream="$(git for-each-ref --format='%(upstream:remotename) %(upstream:remoteref) %(upstream)' "${local_ref}")" || return 1
      if [[ -n "${remote_oid}" || "${upstream}" != "${remote} ${local_ref} ${remote_ref}" ]]; then
        log_warn "[skip] ${branch} has no ${remote_label}"
        skipped=$((skipped + 1))
        continue
      fi

      if [[ "${branch}" == "main" ]]; then
        log_warn "[skip] ${branch} has no ${remote_label}"
        skipped=$((skipped + 1))
        continue
      fi

      if [[ "${branch}" == "${current_branch}" ]]; then
        log_warn "[skip] ${branch} has no ${remote_label} and is current branch"
        skipped=$((skipped + 1))
        continue
      fi

      if ! git show-ref --verify --quiet refs/heads/main; then
        log_warn "[skip] ${branch} has no ${remote_label}; main not found"
        skipped=$((skipped + 1))
        continue
      fi

      if git merge-base --is-ancestor "${local_ref}" refs/heads/main; then
        if branch_worktree_path="$(worktree_path_for_branch "${branch}")"; then
          log_warn "[skip] ${branch} is checked out at ${branch_worktree_path}"
          skipped=$((skipped + 1))
          continue
        fi

        if git branch -d "${branch}" >/dev/null; then
          log_success "[delete] ${branch} merged into main"
          deleted=$((deleted + 1))
        else
          log_error "[failed] ${branch} could not delete"
          failed=$((failed + 1))
        fi
      else
        log_warn "[skip] ${branch} has no ${remote_label} and is not merged into main"
        skipped=$((skipped + 1))
      fi
      continue
    fi

    if [[ -z "${remote_oid}" || "$(git show-ref --verify --hash "${remote_ref}")" != "${remote_oid}" ]]; then
      log_warn "[skip] ${remote_label} does not match ${local_ref} on ${remote}"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "$(git rev-parse "${local_ref}")" == "${remote_oid}" ]]; then
      log_info "[same] ${branch}"
      unchanged=$((unchanged + 1))
      continue
    fi

    if git merge-base --is-ancestor "${remote_oid}" "${local_ref}"; then
      log_info "[ahead] ${branch} has local commits"
      ahead=$((ahead + 1))
      continue
    fi

    if git merge-base --is-ancestor "${local_ref}" "${remote_oid}"; then
      if [[ "${branch}" == "${current_branch}" ]]; then
        if git merge --ff-only "${remote_oid}" >/dev/null; then
          log_success "[fast-forward] ${branch} -> ${remote_label}"
          updated=$((updated + 1))
        else
          log_error "[failed] ${branch} could not fast-forward"
          failed=$((failed + 1))
        fi
      else
        if branch_worktree_path="$(worktree_path_for_branch "${branch}")"; then
          log_warn "[skip] ${branch} is checked out at ${branch_worktree_path}"
          skipped=$((skipped + 1))
          continue
        fi

        if git branch -f "${branch}" "${remote_oid}" >/dev/null; then
          log_success "[fast-forward] ${branch} -> ${remote_label}"
          updated=$((updated + 1))
        else
          log_error "[failed] ${branch} could not fast-forward"
          failed=$((failed + 1))
        fi
      fi
      continue
    fi

    if [[ "${rebase}" != true ]]; then
      log_warn "[skip] ${branch} diverged from ${remote_label}"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "${branch}" != "${current_branch}" ]]; then
      if [[ -z "${initial_head}" ]]; then
        log_warn "[skip] ${branch} cannot switch back to unborn branch ${current_branch} after rebase"
        skipped=$((skipped + 1))
        continue
      fi
      if branch_worktree_path="$(worktree_path_for_branch "${branch}")"; then
        log_warn "[skip] ${branch} is checked out at ${branch_worktree_path}"
        skipped=$((skipped + 1))
        continue
      fi

      if ! git switch --no-guess --quiet "${branch}"; then
        log_error "[failed] ${branch} could not switch for rebase"
        failed=$((failed + 1))
        continue
      fi
    fi

    fork_point="$(git merge-base --fork-point "${remote_ref}" HEAD 2>/dev/null)"
    if [[ -n "${fork_point}" && "$(git rev-parse HEAD)" == "${fork_point}" ]]; then
      if git reset --hard "${remote_oid}" >/dev/null 2>&1; then
        log_success "[reset] ${branch} -> ${remote_label}"
        updated=$((updated + 1))
      else
        log_error "[failed] ${branch} could not reset to ${remote}/${branch}"
        failed=$((failed + 1))
      fi
    elif [[ -n "${fork_point}" ]]; then
      if git rebase --onto "${remote_oid}" "${fork_point}" >/dev/null 2>&1; then
        log_success "[rebase] ${branch} -> ${remote_label}"
        rebased=$((rebased + 1))
      else
        if git rebase --abort >/dev/null 2>&1; then
          log_warn "[skip] ${branch} rebase conflicted; please rebase manually"
          skipped=$((skipped + 1))
        else
          log_error "[failed] ${branch} rebase conflicted and could not abort"
        fi
        failed=$((failed + 1))
      fi
    elif git rebase "${remote_oid}" >/dev/null 2>&1; then
      log_success "[rebase] ${branch} -> ${remote_label}"
      rebased=$((rebased + 1))
    else
      if git rebase --abort >/dev/null 2>&1; then
        log_warn "[skip] ${branch} rebase conflicted; please rebase manually"
        skipped=$((skipped + 1))
      else
        log_error "[failed] ${branch} rebase conflicted and could not abort"
      fi
      failed=$((failed + 1))
    fi

    if [[ "${branch}" != "${current_branch}" ]]; then
      if ! git switch --no-guess --quiet "${current_branch}"; then
        log_error "[failed] could not switch back to ${current_branch}"
        failed=$((failed + 1))
        break
      fi
    fi
  done

  log_done "[done] branches: updated ${updated}, rebased ${rebased}, ahead ${ahead}, deleted ${deleted}, skipped ${skipped}, unchanged ${unchanged}, failed ${failed}"
  (( failed == 0 ))
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  sync_remote_branches "$@"
fi
