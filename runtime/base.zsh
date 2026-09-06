#!/usr/bin/env zsh

_base_script_dir="${${(%):-%N}:A:h}"
. "${_base_script_dir}/logging.zsh"
unset _base_script_dir

link_file() {
  local source_path="${1:-}"
  local target_path="${2:-}"

  if (( $# != 2 )) || [[ -z "${source_path}" || -z "${target_path}" ]]; then
    log_error "Usage: link_file <source> <target>"
    return 1
  fi

  if [[ ! -f "${source_path}" ]]; then
    log_error "Source file not found: ${source_path}"
    return 1
  fi

  if [[ -e "${target_path}" && ! -L "${target_path}" ]]; then
    log_error "Cannot create symbolic link; target exists and is not a symbolic link: ${target_path}"
    return 1
  fi

  ln -sfn -- "${source_path}" "${target_path}"
}
