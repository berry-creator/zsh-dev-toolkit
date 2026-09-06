#!/usr/bin/env zsh

_worktree_script_dir="${${(%):-%N}:A:h}"
. "${_worktree_script_dir}/logging.zsh"

worktree_help() {
  cat <<'EOF'
Usage: worktree.zsh <command> [arguments...]
       . /path/to/worktree.zsh

Run a Git worktree query or command, or source this script to load the
corresponding worktree_* functions into the current zsh process. Use
worktree_help to show this help after sourcing.

Commands:
  kind                   Print main or linked for the current worktree
  current-root           Print the current worktree root
  main-root              Print the main worktree root
  list                   Print registered worktrees as KIND, BRANCH, and PATH
  path-for-branch <branch>
                         Print the worktree where a local branch is checked out
  is-main                Return success when currently in the main worktree
  run <command> [arguments...]
                         Run a command from the current worktree root
  -h, --help             Show this help

Source-only navigation functions:
  worktree_cd_current
                         Change to the current worktree root
  worktree_cd_main       Change to the main worktree root
  worktree_confirm_cd_main
                         Confirm before changing from a linked worktree to the
                         main worktree
  worktree_cd [branch]
                         Change to a branch's worktree; without a branch,
                         interactively select a registered worktree

The lookup and navigation functions do not create, remove, or modify Git
worktrees, refs, or configuration. The run command executes the caller-provided
command unchanged from the current worktree root.
EOF
}

unset _worktree_script_dir

_worktree_require_repository() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "Not inside a Git worktree."
    return 1
  fi
}

_worktree_validate_no_arguments() {
  local function_name="$1"
  shift

  if (( $# != 0 )); then
    log_error "Usage: ${function_name}"
    return 1
  fi
}

worktree_current_root() {
  _worktree_validate_no_arguments "worktree_current_root" "$@" || return 1
  _worktree_require_repository || return 1

  git rev-parse --path-format=absolute --show-toplevel
}

worktree_main_root() {
  local field

  _worktree_validate_no_arguments "worktree_main_root" "$@" || return 1
  _worktree_require_repository || return 1

  while IFS= read -r -d $'\0' field; do
    if [[ "${field}" == worktree\ * ]]; then
      printf '%s\n' "${field#worktree }"
      return 0
    fi
  done < <(git worktree list --porcelain -z)

  log_error "Unable to resolve the main Git worktree."
  return 1
}

worktree_kind() {
  local current_root main_root

  _worktree_validate_no_arguments "worktree_kind" "$@" || return 1
  current_root="$(worktree_current_root)" || return 1
  main_root="$(worktree_main_root)" || return 1

  if [[ "${current_root:A}" == "${main_root:A}" ]]; then
    printf 'main\n'
  else
    printf 'linked\n'
  fi
}

worktree_is_main() {
  local kind

  _worktree_validate_no_arguments "worktree_is_main" "$@" || return 1
  kind="$(worktree_kind)" || return 1
  [[ "${kind}" == "main" ]]
}

worktree_path_for_branch() {
  local branch="${1:-}"
  local field worktree_path=""

  if (( $# != 1 )) || [[ -z "${branch}" ]]; then
    log_error "Usage: worktree_path_for_branch <branch>"
    return 1
  fi

  _worktree_require_repository || return 1

  if ! git check-ref-format --branch "${branch}" >/dev/null 2>&1; then
    log_error "Invalid branch name: ${branch}"
    return 1
  fi

  while IFS= read -r -d $'\0' field; do
    case "${field}" in
      worktree\ *)
        worktree_path="${field#worktree }"
        ;;
      "branch refs/heads/${branch}")
        printf '%s\n' "${worktree_path}"
        return 0
        ;;
      "")
        worktree_path=""
        ;;
    esac
  done < <(git worktree list --porcelain -z)

  return 1
}

worktree_list() {
  local field worktree_path="" branch="" kind="main" index=0

  _worktree_validate_no_arguments "worktree_list" "$@" || return 1
  _worktree_require_repository || return 1

  while IFS= read -r -d $'\0' field; do
    case "${field}" in
      worktree\ *)
        worktree_path="${field#worktree }"
        branch=""
        ;;
      branch\ refs/heads/*)
        branch="${field#branch refs/heads/}"
        ;;
      detached)
        branch="(detached)"
        ;;
      bare)
        branch="(bare)"
        ;;
      "")
        if [[ -n "${worktree_path}" ]]; then
          (( index++ ))
          (( index == 1 )) && kind="main" || kind="linked"
          [[ -n "${branch}" ]] || branch="(unknown)"
          printf '%s\t%s\t%s\n' "${kind}" "${branch}" "${worktree_path}"
        fi
        worktree_path=""
        branch=""
        ;;
    esac
  done < <(git worktree list --porcelain -z)
}

worktree_cd_current() {
  local root

  _worktree_validate_no_arguments "worktree_cd_current" "$@" || return 1
  root="$(worktree_current_root)" || return 1
  builtin cd -- "${root}"
}

worktree_cd_main() {
  local root

  _worktree_validate_no_arguments "worktree_cd_main" "$@" || return 1
  root="$(worktree_main_root)" || return 1
  builtin cd -- "${root}"
}

worktree_confirm_cd_main() {
  local kind current_root main_root confirmation

  _worktree_validate_no_arguments "worktree_confirm_cd_main" "$@" || return 1
  kind="$(worktree_kind)" || return 1
  if [[ "${kind}" == "main" ]]; then
    return 0
  fi

  current_root="$(worktree_current_root)" || return 1
  main_root="$(worktree_main_root)" || return 1

  if [[ ! -t 0 ]]; then
    log_error "Current directory is a linked worktree: ${current_root}"
    log_error "Run this command from the main worktree: ${main_root}"
    return 1
  fi

  log_warn "Current directory is a linked worktree: ${current_root}"
  log_info "Main Git worktree: ${main_root}"
  printf "Type 'yes' to continue from the main worktree: " >&2
  read -r confirmation

  if [[ "${confirmation}" != "yes" ]]; then
    log_info "Worktree switch cancelled"
    return 1
  fi

  builtin cd -- "${main_root}" || return 1
  log_success "Entered main Git worktree: ${main_root}"
}

worktree_cd() {
  local branch="${1:-}"
  local field worktree_path="" record_branch="" choice index=0
  local -a paths branches kinds

  if (( $# > 1 )); then
    log_error "Usage: worktree_cd [branch]"
    return 1
  fi

  _worktree_require_repository || return 1

  if [[ -n "${branch}" ]]; then
    worktree_path="$(worktree_path_for_branch "${branch}")" || {
      log_error "Branch is not checked out in a worktree: ${branch}"
      return 1
    }
    builtin cd -- "${worktree_path}"
    return $?
  fi

  if [[ ! -t 0 ]]; then
    log_error "Interactive worktree selection requires a terminal."
    return 1
  fi

  while IFS= read -r -d $'\0' field; do
    case "${field}" in
      worktree\ *)
        worktree_path="${field#worktree }"
        record_branch=""
        ;;
      branch\ refs/heads/*)
        record_branch="${field#branch refs/heads/}"
        ;;
      detached)
        record_branch="(detached)"
        ;;
      bare)
        record_branch="(bare)"
        ;;
      "")
        if [[ -n "${worktree_path}" ]]; then
          (( index++ ))
          paths+=("${worktree_path}")
          branches+=("${record_branch:-"(unknown)"}")
          (( index == 1 )) && kinds+=("main") || kinds+=("linked")
        fi
        worktree_path=""
        record_branch=""
        ;;
    esac
  done < <(git worktree list --porcelain -z)

  if (( ${#paths[@]} == 0 )); then
    log_error "No registered Git worktrees found."
    return 1
  fi

  for (( index = 1; index <= ${#paths[@]}; index++ )); do
    printf '%d) %-6s %-24s %s\n' \
      "${index}" "${kinds[index]}" "${branches[index]}" "${paths[index]}" >&2
  done

  printf 'Select worktree: ' >&2
  read -r choice

  if ! [[ "${choice}" == <-> ]] || (( choice < 1 || choice > ${#paths[@]} )); then
    log_error "Invalid selection: ${choice}"
    return 1
  fi

  builtin cd -- "${paths[choice]}"
}

worktree_run() {
  local root

  if (( $# == 0 )); then
    log_error "Usage: worktree_run <command> [arguments...]"
    return 1
  fi

  root="$(worktree_current_root)" || return 1

  (
    builtin cd -- "${root}" || return 1
    "$@"
  )
}

_worktree_main() {
  local command="${1:-}"

  if [[ -z "${command}" ]]; then
    worktree_help >&2
    return 1
  fi
  shift

  case "${command}" in
    kind)
      worktree_kind "$@"
      ;;
    current-root)
      worktree_current_root "$@"
      ;;
    main-root)
      worktree_main_root "$@"
      ;;
    list)
      worktree_list "$@"
      ;;
    path-for-branch)
      worktree_path_for_branch "$@"
      ;;
    is-main)
      worktree_is_main "$@"
      ;;
    run)
      worktree_run "$@"
      ;;
    -h|--help)
      worktree_help
      ;;
    *)
      log_error "Unknown worktree command: ${command}"
      worktree_help >&2
      return 1
      ;;
  esac
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  _worktree_main "$@"
fi
