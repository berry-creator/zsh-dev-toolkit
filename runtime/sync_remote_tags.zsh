#!/usr/bin/env zsh

_sync_remote_tags_dir="${${(%):-%N}:A:h}"
. "${_sync_remote_tags_dir}/logging.zsh"
unset _sync_remote_tags_dir

_sync_remote_tags_require_git_repo() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_error "Not inside a Git repository."
    return 1
  fi
}

_sync_remote_tags_require_git_remote() {
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

_sync_remote_tags_usage() {
  cat <<'EOF'
Usage: sync_remote_tags [remote]

Make local tags match the tags published by a Git remote.

Arguments:
  remote                 Remote name to synchronize; defaults to origin

Options:
  -h, --help             Show this help

Behavior:
  - Delete local tags that do not exist on the remote.
  - Replace local tags that differ from same-named remote tags.
  - Fetch tags that exist on the remote but are missing locally.
  - Keep matching local tags unchanged.

This command modifies local tags only. It never creates, updates, or deletes
tags on the remote.
EOF
}

# Make local tags match the tags published by a Git remote.
#
# Usage: sync_remote_tags [remote]
# - Uses origin when no remote is specified.
# - Deletes local tags that do not exist on the remote.
# - Replaces local tags that differ from same-named remote tags.
# - Fetches tags that exist on the remote but are missing locally.
# - Modifies local tags only and never pushes or deletes remote tags.
sync_remote_tags() {
  local remote="${1:-origin}"
  local tag
  local local_ref
  local remote_ref
  local remote_tag
  local added=0
  local updated=0
  local deleted=0
  local unchanged=0
  local failed=0
  local -a local_tags
  local -a remote_tag_lines
  local -A remote_tags

  if (( $# == 1 )) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _sync_remote_tags_usage
    return 0
  fi

  if (( $# > 1 )); then
    log_error "Usage: sync_remote_tags [remote]"
    _sync_remote_tags_usage >&2
    return 1
  fi

  _sync_remote_tags_require_git_repo || return 1
  _sync_remote_tags_require_git_remote "${remote}" || return 1

  log_section "[scan] ${remote} tags"
  remote_tag_lines=("${(@f)$(git ls-remote --tags --refs "${remote}")}") || return 1
  remote_tags=()
  for remote_tag in "${remote_tag_lines[@]}"; do
    if [[ -z "${remote_tag}" ]]; then
      continue
    fi
    remote_tags[${remote_tag#*$'\t'refs/tags/}]="${remote_tag%%$'\t'*}"
  done

  local_tags=("${(@f)$(git tag --list)}")
  for tag in "${local_tags[@]}"; do
    local_ref="$(git rev-parse "refs/tags/${tag}")"
    remote_ref="${remote_tags[${tag}]:-}"

    if [[ -z "${remote_ref}" ]]; then
      if git tag -d "${tag}" >/dev/null; then
        log_success "[delete] ${tag}"
        deleted=$((deleted + 1))
      else
        log_error "[failed] ${tag} could not delete"
        failed=$((failed + 1))
      fi
      continue
    fi

    if [[ "${local_ref}" == "${remote_ref}" ]]; then
      log_info "[same] ${tag}"
      unchanged=$((unchanged + 1))
      continue
    fi

    if git tag -d "${tag}" >/dev/null && git fetch --quiet "${remote}" "refs/tags/${tag}:refs/tags/${tag}" >/dev/null; then
      log_success "[update] ${tag}"
      updated=$((updated + 1))
    else
      log_error "[failed] ${tag} could not update"
      failed=$((failed + 1))
    fi
  done

  for tag in "${(@k)remote_tags}"; do
    if git show-ref --verify --quiet "refs/tags/${tag}"; then
      continue
    fi

    if git fetch --quiet "${remote}" "refs/tags/${tag}:refs/tags/${tag}" >/dev/null; then
      log_success "[add] ${tag}"
      added=$((added + 1))
    else
      log_error "[failed] ${tag} could not add"
      failed=$((failed + 1))
    fi
  done

  log_done "[done] tags: added ${added}, updated ${updated}, deleted ${deleted}, unchanged ${unchanged}, failed ${failed}"
  (( failed == 0 ))
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  sync_remote_tags "$@"
fi
