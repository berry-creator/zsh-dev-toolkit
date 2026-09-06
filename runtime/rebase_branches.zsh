#!/usr/bin/env zsh

_rebase_branches_dir="${${(%):-%N}:A:h}"
. "${_rebase_branches_dir}/logging.zsh"
. "${_rebase_branches_dir}/worktree.zsh"
unset _rebase_branches_dir

_rebase_branches_require_git_repo() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_error "Not inside a Git repository."
    return 1
  fi
}

_rebase_branches_require_git_remote() {
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

_rebase_branches_git_operation_in_progress() {
  [[ -d "$(git rev-parse --git-path rebase-merge)" ]] ||
    [[ -d "$(git rev-parse --git-path rebase-apply)" ]] ||
    [[ -f "$(git rev-parse --git-path MERGE_HEAD)" ]] ||
    [[ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]] ||
    [[ -f "$(git rev-parse --git-path REVERT_HEAD)" ]]
}

_rebase_branches_backup_branch_name() {
  local branch="$1"
  local timestamp="$2"

  printf 'backup/%s/before-rebase-%s\n' "${branch}" "${timestamp}"
}

_rebase_branches_usage() {
  cat <<'EOF'
Usage: rebase_branches <base-commit> [target-branch]

Interactively rebase local branches that diverged at a specific commit onto
the latest version of a target branch.

Arguments:
  base-commit            Commit where candidate branches diverged
  target-branch          Local target branch to update and rebase onto;
                         defaults to main

Options:
  -h, --help             Show this help

Behavior:
  - Fetch and prune origin, then fast-forward the local target branch.
  - List local branches whose merge base with the target equals base-commit
    and that do not already contain the updated target branch.
  - Prompt for the branches to process.
  - Create backup/<branch>/before-rebase-<timestamp> before each rebase.
  - Abort a rebase automatically when conflicts occur.

This command requires a clean worktree and no Git operation in progress. It
prompts before leaving a linked worktree, modifies local branches only, and
never pushes rebased branches to origin. A non-interactive shell fails when
started from a linked worktree.
EOF
}

# Interactively rebase local branches that diverged at a specific commit onto
# the latest version of a target branch.
#
# Usage: rebase_branches <base-commit> [target-branch]
# - The target branch defaults to main and is fast-forwarded from origin first.
# - Only local branches whose merge base equals base-commit and that do not
#   already contain the updated target branch are offered for selection.
# - A timestamped backup branch is created before each rebase.
# - Conflicted rebases are aborted automatically.
# - A clean worktree with no Git operation in progress is required.
# - Branches checked out in linked worktrees are skipped.
# - Rebased branches are never pushed automatically.
rebase_branches() {
  local remote="origin"
  local base_commit="${1:-}"
  local target_branch="${2:-main}"
  local target_ref="refs/heads/${target_branch}"
  local remote_target_ref="refs/remotes/${remote}/${target_branch}"
  local resolved_base
  local current_branch
  local branch
  local branch_merge_base
  local branch_worktree_path
  local backup_branch
  local timestamp
  local reply
  local item
  local index
  local rebased=0
  local conflicted=0
  local skipped=0
  local failed=0
  local -a branches
  local -a candidates
  local -a selected_branches
  local -A seen_indexes

  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _rebase_branches_usage
    return 0
  fi

  if (( $# < 1 || $# > 2 )); then
    log_error "Usage: rebase_branches <base-commit> [target-branch]"
    _rebase_branches_usage >&2
    return 1
  fi

  _rebase_branches_require_git_repo || return 1
  _rebase_branches_require_git_remote "${remote}" || return 1
  worktree_confirm_cd_main || return 1

  if ! git check-ref-format --branch "${target_branch}" >/dev/null 2>&1; then
    log_error "Invalid target branch: ${target_branch}"
    return 1
  fi

  if ! resolved_base="$(git rev-parse --verify "${base_commit}^{commit}" 2>/dev/null)"; then
    log_error "Commit not found: ${base_commit}"
    return 1
  fi

  if ! git show-ref --verify --quiet "${target_ref}"; then
    log_error "Local target branch not found: ${target_branch}"
    return 1
  fi

  current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)"
  if [[ -z "${current_branch}" ]]; then
    log_error "Cannot rebase branches from detached HEAD."
    return 1
  fi

  if _rebase_branches_git_operation_in_progress; then
    log_error "Cannot rebase branches while another Git operation is in progress."
    return 1
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    log_error "Cannot rebase branches with uncommitted changes."
    return 1
  fi

  log_info "[fetch] ${remote} branches"
  git fetch --quiet "${remote}" --prune || return 1

  if ! git show-ref --verify --quiet "${remote_target_ref}"; then
    log_error "${remote}/${target_branch} not found."
    return 1
  fi

  if [[ "${current_branch}" != "${target_branch}" ]]; then
    if branch_worktree_path="$(worktree_path_for_branch "${target_branch}")"; then
      log_error "Target branch ${target_branch} is checked out at ${branch_worktree_path}"
      return 1
    fi
    git switch --quiet "${target_branch}" || return 1
  fi

  if git merge --ff-only "${remote_target_ref}" >/dev/null; then
    log_success "[${target_branch}] updated to $(git rev-parse --short "${target_ref}")"
  else
    log_error "Cannot fast-forward ${target_branch} to ${remote}/${target_branch}."
    if [[ "${current_branch}" != "${target_branch}" ]]; then
      git switch --quiet "${current_branch}" >/dev/null 2>&1
    fi
    return 1
  fi

  branches=("${(@f)$(git for-each-ref --format='%(refname:short)' refs/heads)}")
  candidates=()

  for branch in "${branches[@]}"; do
    if [[ "${branch}" == "${target_branch}" ]] || [[ "${branch}" == backup/* ]]; then
      continue
    fi

    if branch_worktree_path="$(worktree_path_for_branch "${branch}")"; then
      log_warn "[skip] ${branch} is checked out at ${branch_worktree_path}"
      skipped=$((skipped + 1))
      continue
    fi

    if git merge-base --is-ancestor "${target_ref}" "refs/heads/${branch}"; then
      continue
    fi

    branch_merge_base="$(git merge-base "${target_ref}" "refs/heads/${branch}")" || {
      log_warn "[skip] ${branch} has no merge-base with ${target_branch}"
      skipped=$((skipped + 1))
      continue
    }

    if [[ "${branch_merge_base}" == "${resolved_base}" ]]; then
      candidates+=("${branch}")
    fi
  done

  if (( ${#candidates[@]} == 0 )); then
    log_done "[done] no branches need rebase"
    if [[ "${current_branch}" != "${target_branch}" ]]; then
      git switch --quiet "${current_branch}" || return 1
    fi
    return 0
  fi

  log_section "[scan] branches based on ${resolved_base[1,12]} and not linear with ${target_branch}:"
  for (( index = 1; index <= ${#candidates[@]}; index++ )); do
    echo "  ${index}) ${candidates[${index}]}"
  done

  printf 'Enter branch numbers to rebase, separated by commas. Empty input cancels: '
  read -r reply
  reply="${reply//[[:space:]]/}"

  if [[ -z "${reply}" ]]; then
    log_info "[cancel] no branches rebased"
    if [[ "${current_branch}" != "${target_branch}" ]]; then
      git switch --quiet "${current_branch}" || return 1
    fi
    return 0
  fi

  selected_branches=()
  seen_indexes=()
  for item in "${(@s:,:)reply}"; do
    if [[ -z "${item}" ]] || [[ "${item}" != <-> ]]; then
      log_error "Invalid branch number: ${item}"
      if [[ "${current_branch}" != "${target_branch}" ]]; then
        git switch --quiet "${current_branch}" >/dev/null 2>&1
      fi
      return 1
    fi

    index="${item}"
    if (( index < 1 || index > ${#candidates[@]} )); then
      log_error "Branch number out of range: ${index}"
      if [[ "${current_branch}" != "${target_branch}" ]]; then
        git switch --quiet "${current_branch}" >/dev/null 2>&1
      fi
      return 1
    fi

    if [[ -n "${seen_indexes[${index}]:-}" ]]; then
      continue
    fi

    seen_indexes[${index}]=1
    selected_branches+=("${candidates[${index}]}")
  done

  timestamp="$(date +%Y%m%d%H%M%S)"
  for branch in "${selected_branches[@]}"; do
    backup_branch="$(_rebase_branches_backup_branch_name "${branch}" "${timestamp}")"

    if git show-ref --verify --quiet "refs/heads/${backup_branch}"; then
      log_error "[failed] ${branch} backup already exists: ${backup_branch}"
      failed=$((failed + 1))
      continue
    fi

    if ! git branch "${backup_branch}" "${branch}" >/dev/null; then
      log_error "[failed] ${branch} could not create backup"
      failed=$((failed + 1))
      continue
    fi
    log_success "[backup] ${branch} -> ${backup_branch}"

    if ! git switch --quiet "${branch}"; then
      log_error "[failed] ${branch} could not switch for rebase"
      failed=$((failed + 1))
      continue
    fi

    if git rebase "${target_ref}" >/dev/null 2>&1; then
      log_success "[rebase] ${branch} onto ${target_branch}"
      log_info "[push] ${branch} rebased; push with: git push --force-with-lease ${remote} ${branch}"
      rebased=$((rebased + 1))
    else
      if git rebase --abort >/dev/null 2>&1; then
        log_warn "[skip] ${branch} rebase conflicted; aborted, please rebase manually"
        conflicted=$((conflicted + 1))
      else
        log_error "[failed] ${branch} rebase conflicted and could not abort"
        failed=$((failed + 1))
        break
      fi
    fi
  done

  if [[ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" != "${current_branch}" ]]; then
    if ! git switch --quiet "${current_branch}"; then
      log_error "[failed] could not switch back to ${current_branch}"
      failed=$((failed + 1))
    fi
  fi

  log_done "[done] branches: rebased ${rebased}, conflicted ${conflicted}, skipped ${skipped}, failed ${failed}"
  (( failed == 0 ))
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  rebase_branches "$@"
fi
