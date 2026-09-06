#!/usr/bin/env zsh

_submodule_script_dir="${${(%):-%N}:A:h}"
. "${_submodule_script_dir}/logging.zsh"

submodule_help() {
  cat <<'EOF'
Usage: submodule.zsh <command> [arguments...]
       . /path/to/submodule.zsh

Run a generic Git submodule command, or source this script to load the
corresponding submodule_* functions into the current zsh process. Use
submodule_help to show this help after sourcing.

Query commands:
  resolve <parent> <name-or-path>
  name <parent> <name-or-path>
  is-registered <parent> <name-or-path>
  is-initialized <parent> <name-or-path>
  remote-branch-exists <parent> <name-or-path> <remote> <branch>
  status <parent> <name-or-path>

Operation commands:
  sync <parent> <name-or-path>
  init <parent> <name-or-path> [filter]
  fetch <parent> <name-or-path> <remote>
  checkout-remote-branch <parent> <name-or-path> <remote> <branch>
  reset-remote-branch <parent> <name-or-path> <remote> <branch>
  apply-sparse-file <parent> <name-or-path> <patterns-file|->
  deinit <parent> <name-or-path>
  purge <parent> <name-or-path>

Options:
  -h, --help             Show this help

All submodules must be registered in the parent repository's .gitmodules and
index. Reset and purge are explicitly destructive operations.
EOF
}

unset _submodule_script_dir

_submodule_check_argument_count() {
  local function_name="$1"
  local minimum="$2"
  local maximum="$3"
  local actual="$4"
  local usage="$5"

  if (( actual < minimum || actual > maximum )); then
    log_error "Usage: ${function_name} ${usage}"
    return 1
  fi
}

_submodule_parent_root() {
  local parent="${1:-}"
  local root

  if [[ -z "${parent}" ]] || [[ ! -d "${parent}" ]]; then
    log_error "Parent repository directory not found: ${parent}"
    return 1
  fi

  root="$(git -C "${parent}" rev-parse --path-format=absolute --show-toplevel 2>/dev/null)" || {
    log_error "Not inside a Git worktree: ${parent}"
    return 1
  }

  if [[ ! -f "${root}/.gitmodules" ]]; then
    log_error "Missing .gitmodules under parent repository: ${root}"
    return 1
  fi

  printf '%s\n' "${root}"
}

_submodule_name_for_path() {
  local parent_root="$1"
  local expected_path="$2"
  local key name configured_path

  while IFS= read -r key; do
    configured_path="$(git -C "${parent_root}" config --file .gitmodules --get "${key}")" || continue
    if [[ "${configured_path}" == "${expected_path}" ]]; then
      name="${key#submodule.}"
      printf '%s\n' "${name%.path}"
      return 0
    fi
  done < <(git -C "${parent_root}" config --file .gitmodules --name-only --get-regexp '^submodule\..*\.path$' 2>/dev/null)

  return 1
}

_submodule_repo_path() {
  local parent_root="$1"
  local submodule_path="$2"
  local absolute_parent="${parent_root:A}"
  local repo_path="${parent_root}/${submodule_path}"

  if [[ "${submodule_path}" == *$'\t'* || "${submodule_path}" == *$'\n'* ]]; then
    log_error "Submodule paths containing tabs or newlines are not supported."
    return 1
  fi

  repo_path="${repo_path:A}"
  case "${repo_path}" in
    "${absolute_parent}"/*)
      printf '%s\n' "${repo_path}"
      ;;
    *)
      log_error "Submodule path escapes its parent repository: ${submodule_path}"
      return 1
      ;;
  esac
}

_submodule_require_registered() {
  local parent_root="$1"
  local submodule_path="$2"
  local mode

  mode="$(git -C "${parent_root}" ls-files --stage -- "${submodule_path}" | awk 'NR == 1 { print $1 }')"
  if [[ "${mode}" != "160000" ]]; then
    log_error "Submodule is not registered in the parent index: ${submodule_path}"
    return 1
  fi
}

_submodule_resolve_context() {
  local parent="$1"
  local input="$2"
  local parent_root submodule_path

  parent_root="$(_submodule_parent_root "${parent}")" || return 1
  submodule_path="$(submodule_resolve "${parent_root}" "${input}")" || return 1
  _submodule_require_registered "${parent_root}" "${submodule_path}" || return 1
  printf '%s\t%s\n' "${parent_root}" "${submodule_path}"
}

_submodule_require_initialized() {
  local parent_root="$1"
  local submodule_path="$2"
  local repo_path toplevel

  repo_path="$(_submodule_repo_path "${parent_root}" "${submodule_path}")" || return 1
  if [[ ! -d "${repo_path}" ]]; then
    log_error "Submodule is not initialized: ${submodule_path}"
    return 1
  fi

  toplevel="$(git -C "${repo_path}" rev-parse --path-format=absolute --show-toplevel 2>/dev/null)" || {
    log_error "Submodule is not initialized: ${submodule_path}"
    return 1
  }

  if [[ "${toplevel:A}" != "${repo_path:A}" ]]; then
    log_error "Path is not a submodule worktree root: ${repo_path}"
    return 1
  fi
}

_submodule_require_remote() {
  local repo_path="$1"
  local remote="$2"

  if [[ -z "${remote}" ]] || ! git -C "${repo_path}" remote get-url "${remote}" >/dev/null 2>&1; then
    log_error "Submodule remote not found: ${remote}"
    return 1
  fi
}

_submodule_validate_branch() {
  local branch="$1"

  if [[ -z "${branch}" ]] || ! git check-ref-format --branch "${branch}" >/dev/null 2>&1; then
    log_error "Invalid branch name: ${branch}"
    return 1
  fi
}

submodule_resolve() {
  local parent="${1:-}"
  local input="${2:-}"
  local parent_root key name configured_path

  _submodule_check_argument_count "submodule_resolve" 2 2 "$#" "<parent> <name-or-path>" || return 1
  parent_root="$(_submodule_parent_root "${parent}")" || return 1

  while IFS= read -r key; do
    configured_path="$(git -C "${parent_root}" config --file .gitmodules --get "${key}")" || continue
    name="${key#submodule.}"
    name="${name%.path}"

    if [[ "${input}" == "${name}" || "${input}" == "${configured_path}" ]]; then
      _submodule_repo_path "${parent_root}" "${configured_path}" >/dev/null || return 1
      printf '%s\n' "${configured_path}"
      return 0
    fi
  done < <(git -C "${parent_root}" config --file .gitmodules --name-only --get-regexp '^submodule\..*\.path$' 2>/dev/null)

  log_error "Submodule is not configured in ${parent_root}/.gitmodules: ${input}"
  return 1
}

submodule_name() {
  local parent="${1:-}"
  local input="${2:-}"
  local parent_root submodule_path

  _submodule_check_argument_count "submodule_name" 2 2 "$#" "<parent> <name-or-path>" || return 1
  parent_root="$(_submodule_parent_root "${parent}")" || return 1
  submodule_path="$(submodule_resolve "${parent_root}" "${input}")" || return 1
  _submodule_name_for_path "${parent_root}" "${submodule_path}"
}

submodule_is_registered() {
  local parent="${1:-}"
  local input="${2:-}"
  local parent_root submodule_path

  _submodule_check_argument_count "submodule_is_registered" 2 2 "$#" "<parent> <name-or-path>" || return 1
  parent_root="$(_submodule_parent_root "${parent}")" || return 1
  submodule_path="$(submodule_resolve "${parent_root}" "${input}")" || return 1
  _submodule_require_registered "${parent_root}" "${submodule_path}" 2>/dev/null
}

submodule_is_initialized() {
  local context parent_root submodule_path

  _submodule_check_argument_count "submodule_is_initialized" 2 2 "$#" "<parent> <name-or-path>" || return 1
  context="$(_submodule_resolve_context "$1" "$2")" || return 1
  parent_root="${context%%$'\t'*}"
  submodule_path="${context#*$'\t'}"
  _submodule_require_initialized "${parent_root}" "${submodule_path}" 2>/dev/null
}

submodule_sync() {
  local context parent_root submodule_path

  _submodule_check_argument_count "submodule_sync" 2 2 "$#" "<parent> <name-or-path>" || return 1
  context="$(_submodule_resolve_context "$1" "$2")" || return 1
  parent_root="${context%%$'\t'*}"
  submodule_path="${context#*$'\t'}"

  git -C "${parent_root}" submodule sync -- "${submodule_path}"
}

submodule_init() {
  local context parent_root submodule_path filter="${3:-}"
  local -a arguments

  _submodule_check_argument_count "submodule_init" 2 3 "$#" "<parent> <name-or-path> [filter]" || return 1
  context="$(_submodule_resolve_context "$1" "$2")" || return 1
  parent_root="${context%%$'\t'*}"
  submodule_path="${context#*$'\t'}"

  submodule_sync "${parent_root}" "${submodule_path}" || return 1
  arguments=(submodule update --init)
  [[ -n "${filter}" ]] && arguments+=("--filter=${filter}")
  arguments+=(-- "${submodule_path}")
  git -C "${parent_root}" -c fetch.recurseSubmodules=false "${arguments[@]}"
}

submodule_fetch() {
  local context parent_root submodule_path repo_path remote="${3:-}"

  _submodule_check_argument_count "submodule_fetch" 3 3 "$#" "<parent> <name-or-path> <remote>" || return 1
  context="$(_submodule_resolve_context "$1" "$2")" || return 1
  parent_root="${context%%$'\t'*}"
  submodule_path="${context#*$'\t'}"
  _submodule_require_initialized "${parent_root}" "${submodule_path}" || return 1
  repo_path="$(_submodule_repo_path "${parent_root}" "${submodule_path}")" || return 1
  _submodule_require_remote "${repo_path}" "${remote}" || return 1

  git -C "${repo_path}" -c fetch.recurseSubmodules=false fetch --prune "${remote}"
}

submodule_remote_branch_exists() {
  local context parent_root submodule_path repo_path remote="${3:-}" branch="${4:-}"

  _submodule_check_argument_count "submodule_remote_branch_exists" 4 4 "$#" \
    "<parent> <name-or-path> <remote> <branch>" || return 1
  context="$(_submodule_resolve_context "$1" "$2")" || return 1
  parent_root="${context%%$'\t'*}"
  submodule_path="${context#*$'\t'}"
  _submodule_require_initialized "${parent_root}" "${submodule_path}" || return 1
  repo_path="$(_submodule_repo_path "${parent_root}" "${submodule_path}")" || return 1
  _submodule_require_remote "${repo_path}" "${remote}" || return 1
  _submodule_validate_branch "${branch}" || return 1

  git -C "${repo_path}" show-ref --verify --quiet "refs/remotes/${remote}/${branch}"
}

submodule_checkout_remote_branch() {
  local context parent_root submodule_path repo_path remote="${3:-}" branch="${4:-}"

  _submodule_check_argument_count "submodule_checkout_remote_branch" 4 4 "$#" \
    "<parent> <name-or-path> <remote> <branch>" || return 1
  context="$(_submodule_resolve_context "$1" "$2")" || return 1
  parent_root="${context%%$'\t'*}"
  submodule_path="${context#*$'\t'}"
  _submodule_require_initialized "${parent_root}" "${submodule_path}" || return 1
  repo_path="$(_submodule_repo_path "${parent_root}" "${submodule_path}")" || return 1
  _submodule_require_remote "${repo_path}" "${remote}" || return 1
  _submodule_validate_branch "${branch}" || return 1

  if ! submodule_remote_branch_exists "${parent_root}" "${submodule_path}" "${remote}" "${branch}"; then
    log_error "Remote submodule branch not found: ${remote}/${branch}"
    return 1
  fi

  if git -C "${repo_path}" show-ref --verify --quiet "refs/heads/${branch}"; then
    git -C "${repo_path}" switch "${branch}"
  else
    git -C "${repo_path}" switch --track -c "${branch}" "${remote}/${branch}"
  fi
}

submodule_reset_remote_branch() {
  local context parent_root submodule_path repo_path remote="${3:-}" branch="${4:-}"

  _submodule_check_argument_count "submodule_reset_remote_branch" 4 4 "$#" \
    "<parent> <name-or-path> <remote> <branch>" || return 1
  context="$(_submodule_resolve_context "$1" "$2")" || return 1
  parent_root="${context%%$'\t'*}"
  submodule_path="${context#*$'\t'}"
  _submodule_require_initialized "${parent_root}" "${submodule_path}" || return 1
  repo_path="$(_submodule_repo_path "${parent_root}" "${submodule_path}")" || return 1
  _submodule_require_remote "${repo_path}" "${remote}" || return 1
  _submodule_validate_branch "${branch}" || return 1

  if ! submodule_remote_branch_exists "${parent_root}" "${submodule_path}" "${remote}" "${branch}"; then
    log_error "Remote submodule branch not found: ${remote}/${branch}"
    return 1
  fi

  git -C "${repo_path}" checkout -B "${branch}" "${remote}/${branch}" || return 1
  git -C "${repo_path}" reset --hard "${remote}/${branch}" || return 1
  git -C "${repo_path}" branch --set-upstream-to="${remote}/${branch}" "${branch}" >/dev/null
}

submodule_apply_sparse_file() {
  local context parent_root submodule_path repo_path patterns_file="${3:-}"
  local sparse_file

  _submodule_check_argument_count "submodule_apply_sparse_file" 3 3 "$#" \
    "<parent> <name-or-path> <patterns-file|->" || return 1
  if [[ "${patterns_file}" != "-" && ! -f "${patterns_file}" ]]; then
    log_error "Sparse-checkout patterns file not found: ${patterns_file}"
    return 1
  fi
  [[ "${patterns_file}" == "-" ]] || patterns_file="${patterns_file:A}"

  context="$(_submodule_resolve_context "$1" "$2")" || return 1
  parent_root="${context%%$'\t'*}"
  submodule_path="${context#*$'\t'}"
  _submodule_require_initialized "${parent_root}" "${submodule_path}" || return 1
  repo_path="$(_submodule_repo_path "${parent_root}" "${submodule_path}")" || return 1

  git -C "${repo_path}" sparse-checkout init --no-cone || return 1
  sparse_file="$(git -C "${repo_path}" rev-parse --path-format=absolute --git-path info/sparse-checkout)" || return 1
  if [[ "${patterns_file}" == "-" ]]; then
    cat > "${sparse_file}" || return 1
  else
    cp -- "${patterns_file}" "${sparse_file}" || return 1
  fi
  git -C "${repo_path}" read-tree -mu HEAD
}

submodule_status() {
  local context parent_root submodule_path submodule_name repo_path
  local configured_url recorded_commit branch head describe dirty="false"

  _submodule_check_argument_count "submodule_status" 2 2 "$#" "<parent> <name-or-path>" || return 1
  context="$(_submodule_resolve_context "$1" "$2")" || return 1
  parent_root="${context%%$'\t'*}"
  submodule_path="${context#*$'\t'}"
  submodule_name="$(_submodule_name_for_path "${parent_root}" "${submodule_path}")" || return 1
  repo_path="$(_submodule_repo_path "${parent_root}" "${submodule_path}")" || return 1
  configured_url="$(git -C "${parent_root}" config --file .gitmodules --get "submodule.${submodule_name}.url" || true)"
  recorded_commit="$(git -C "${parent_root}" ls-files --stage -- "${submodule_path}" | awk '$1 == "160000" { print $2; exit }')"

  printf 'name=%s\n' "${submodule_name}"
  printf 'path=%s\n' "${submodule_path}"
  printf 'configured_url=%s\n' "${configured_url}"
  printf 'recorded_commit=%s\n' "${recorded_commit}"

  if ! _submodule_require_initialized "${parent_root}" "${submodule_path}" 2>/dev/null; then
    printf 'initialized=false\n'
    return 0
  fi

  branch="$(git -C "${repo_path}" branch --show-current)"
  [[ -n "${branch}" ]] || branch="detached"
  head="$(git -C "${repo_path}" rev-parse HEAD)" || return 1
  describe="$(git -C "${repo_path}" describe --tags --always --dirty 2>/dev/null || git -C "${repo_path}" rev-parse --short HEAD)"
  [[ -z "$(git -C "${repo_path}" status --porcelain --untracked-files=all)" ]] || dirty="true"

  printf 'initialized=true\n'
  printf 'branch=%s\n' "${branch}"
  printf 'head=%s\n' "${head}"
  printf 'describe=%s\n' "${describe}"
  printf 'dirty=%s\n' "${dirty}"
}

submodule_deinit() {
  local context parent_root submodule_path

  _submodule_check_argument_count "submodule_deinit" 2 2 "$#" "<parent> <name-or-path>" || return 1
  context="$(_submodule_resolve_context "$1" "$2")" || return 1
  parent_root="${context%%$'\t'*}"
  submodule_path="${context#*$'\t'}"

  git -C "${parent_root}" submodule deinit -- "${submodule_path}"
}

submodule_purge() {
  local context parent_root submodule_path submodule_name repo_path
  local modules_root module_git_dir

  _submodule_check_argument_count "submodule_purge" 2 2 "$#" "<parent> <name-or-path>" || return 1
  context="$(_submodule_resolve_context "$1" "$2")" || return 1
  parent_root="${context%%$'\t'*}"
  submodule_path="${context#*$'\t'}"
  submodule_name="$(_submodule_name_for_path "${parent_root}" "${submodule_path}")" || return 1
  repo_path="$(_submodule_repo_path "${parent_root}" "${submodule_path}")" || return 1
  modules_root="$(git -C "${parent_root}" rev-parse --path-format=absolute --git-path modules)" || return 1
  module_git_dir="$(git -C "${parent_root}" rev-parse --path-format=absolute --git-path "modules/${submodule_name}")" || return 1

  case "${module_git_dir:A}" in
    "${modules_root:A}"/*) ;;
    *)
      log_error "Submodule Git directory escapes the modules root: ${module_git_dir}"
      return 1
      ;;
  esac

  git -C "${parent_root}" submodule deinit -f -- "${submodule_path}" >/dev/null 2>&1 || true
  [[ ! -e "${repo_path}" && ! -L "${repo_path}" ]] || rm -rf -- "${repo_path}"
  [[ ! -e "${module_git_dir}" && ! -L "${module_git_dir}" ]] || rm -rf -- "${module_git_dir}"
  rmdir "${modules_root}" 2>/dev/null || true
  git -C "${parent_root}" checkout -- "${submodule_path}"
}

_submodule_main() {
  local command="${1:-}"

  if [[ -z "${command}" ]]; then
    submodule_help >&2
    return 1
  fi
  shift

  case "${command}" in
    resolve)
      submodule_resolve "$@"
      ;;
    name)
      submodule_name "$@"
      ;;
    is-registered)
      submodule_is_registered "$@"
      ;;
    is-initialized)
      submodule_is_initialized "$@"
      ;;
    remote-branch-exists)
      submodule_remote_branch_exists "$@"
      ;;
    status)
      submodule_status "$@"
      ;;
    sync)
      submodule_sync "$@"
      ;;
    init)
      submodule_init "$@"
      ;;
    fetch)
      submodule_fetch "$@"
      ;;
    checkout-remote-branch)
      submodule_checkout_remote_branch "$@"
      ;;
    reset-remote-branch)
      submodule_reset_remote_branch "$@"
      ;;
    apply-sparse-file)
      submodule_apply_sparse_file "$@"
      ;;
    deinit)
      submodule_deinit "$@"
      ;;
    purge)
      submodule_purge "$@"
      ;;
    -h|--help)
      submodule_help
      ;;
    *)
      log_error "Unknown submodule command: ${command}"
      submodule_help >&2
      return 1
      ;;
  esac
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  _submodule_main "$@"
fi
