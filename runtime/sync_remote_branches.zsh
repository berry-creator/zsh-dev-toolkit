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

_sync_remote_branches_usage() {
  cat <<'EOF'
Usage: sync_remote_branches [--rebase]

Synchronize local branches with same-named branches on origin.

Behavior:
  - Fetch and prune origin before comparing branches.
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
  Branches checked out in other worktrees are skipped when an update, delete,
  or rebase would modify them.
  This command can modify or delete local branches, but never pushes to origin.
EOF
}

# Synchronize local branches with same-named branches on origin.
#
# Usage: sync_remote_branches [--rebase]
# - Always uses origin and runs fetch --prune before comparing branches.
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
  local current_branch
  local branch
  local fork_point
  local local_ref
  local remote_ref
  local upstream_ref
  local branch_worktree_path
  local updated=0
  local rebased=0
  local ahead=0
  local deleted=0
  local skipped=0
  local unchanged=0
  local failed=0
  local -a branches

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

  current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)"
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

  log_info "[fetch] ${remote} branches"
  git fetch --quiet "${remote}" --prune || return 1

  branches=("${(@f)$(git for-each-ref --format='%(refname:short)' refs/heads)}")

  if (( ${#branches[@]} == 0 )); then
    log_done "[done] branches: updated 0, rebased 0, ahead 0, deleted 0, skipped 0, unchanged 0, failed 0"
    return 0
  fi

  for branch in "${branches[@]}"; do
    local_ref="refs/heads/${branch}"
    remote_ref="refs/remotes/${remote}/${branch}"
    upstream_ref="$(git for-each-ref --format='%(upstream)' "${local_ref}")"

    if ! git show-ref --verify --quiet "${remote_ref}"; then
      if [[ "${upstream_ref}" != "${remote_ref}" ]]; then
        log_warn "[skip] ${branch} has no ${remote}/${branch}"
        skipped=$((skipped + 1))
        continue
      fi

      if [[ "${branch}" == "main" ]]; then
        log_warn "[skip] ${branch} has no ${remote}/${branch}"
        skipped=$((skipped + 1))
        continue
      fi

      if [[ "${branch}" == "${current_branch}" ]]; then
        log_warn "[skip] ${branch} has no ${remote}/${branch} and is current branch"
        skipped=$((skipped + 1))
        continue
      fi

      if ! git show-ref --verify --quiet refs/heads/main; then
        log_warn "[skip] ${branch} has no ${remote}/${branch}; main not found"
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
        log_warn "[skip] ${branch} has no ${remote}/${branch} and is not merged into main"
        skipped=$((skipped + 1))
      fi
      continue
    fi

    if [[ "$(git rev-parse "${local_ref}")" == "$(git rev-parse "${remote_ref}")" ]]; then
      log_info "[same] ${branch}"
      unchanged=$((unchanged + 1))
      continue
    fi

    if git merge-base --is-ancestor "${remote_ref}" "${local_ref}"; then
      log_info "[ahead] ${branch} has local commits"
      ahead=$((ahead + 1))
      continue
    fi

    if git merge-base --is-ancestor "${local_ref}" "${remote_ref}"; then
      if [[ "${branch}" == "${current_branch}" ]]; then
        if git merge --ff-only "${remote}/${branch}" >/dev/null; then
          log_success "[fast-forward] ${branch} -> ${remote}/${branch}"
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

        if git branch -f "${branch}" "${remote}/${branch}" >/dev/null; then
          log_success "[fast-forward] ${branch} -> ${remote}/${branch}"
          updated=$((updated + 1))
        else
          log_error "[failed] ${branch} could not fast-forward"
          failed=$((failed + 1))
        fi
      fi
      continue
    fi

    if [[ "${rebase}" != true ]]; then
      log_warn "[skip] ${branch} diverged from ${remote}/${branch}"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ "${branch}" != "${current_branch}" ]]; then
      if branch_worktree_path="$(worktree_path_for_branch "${branch}")"; then
        log_warn "[skip] ${branch} is checked out at ${branch_worktree_path}"
        skipped=$((skipped + 1))
        continue
      fi

      if ! git switch --quiet "${branch}"; then
        log_error "[failed] ${branch} could not switch for rebase"
        failed=$((failed + 1))
        continue
      fi
    fi

    fork_point="$(git merge-base --fork-point "${remote}/${branch}" HEAD 2>/dev/null)"
    if [[ -n "${fork_point}" && "$(git rev-parse HEAD)" == "${fork_point}" ]]; then
      if git reset --hard "${remote}/${branch}" >/dev/null 2>&1; then
        log_success "[reset] ${branch} -> ${remote}/${branch}"
        updated=$((updated + 1))
      else
        log_error "[failed] ${branch} could not reset to ${remote}/${branch}"
        failed=$((failed + 1))
      fi
    elif [[ -n "${fork_point}" ]]; then
      if git rebase --onto "${remote}/${branch}" "${fork_point}" >/dev/null 2>&1; then
        log_success "[rebase] ${branch} -> ${remote}/${branch}"
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
    elif git rebase "${remote}/${branch}" >/dev/null 2>&1; then
      log_success "[rebase] ${branch} -> ${remote}/${branch}"
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
      if ! git switch --quiet "${current_branch}"; then
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
