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

link_directory() {
  local source_path="${1:-}" target_path="${2:-}" parent relative

  if (( $# != 2 )) || [[ -z "$source_path" || -z "$target_path" ]]; then
    log_error "Usage: link_directory <source-directory> <target-path>"
    return 1
  fi
  [[ -d "$source_path" ]] || { log_error "Source directory not found: $source_path"; return 1; }
  source_path="${source_path:A}"
  target_path="${target_path:a}"
  parent="${target_path:h}"
  if [[ -L "$target_path" ]]; then
    [[ "${target_path:A}" == "$source_path" ]] && return 0
    log_error "Different symbolic link already exists: $target_path"
    return 1
  fi
  if [[ -e "$target_path" ]]; then
    log_error "Directory link target already exists: $target_path"
    return 1
  fi
  mkdir -p -- "$parent" || return 1
  relative="$(realpath --relative-to="$parent" -- "$source_path")" || return 1
  ln -s -- "$relative" "$target_path"
}
