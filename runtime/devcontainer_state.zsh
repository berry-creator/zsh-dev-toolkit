#!/usr/bin/env zsh

_devcontainer_state_script_dir="${${(%):-%N}:A:h}"
. "${_devcontainer_state_script_dir}/logging.zsh"
_devcontainer_state_config="${_devcontainer_state_script_dir}/devcontainer_state.conf"
unset _devcontainer_state_script_dir

_devcontainer_state_help() {
  cat <<'EOF'
Usage: devcontainer_state.zsh <backup [--recreate]|restore>
       . /path/to/devcontainer_state.zsh

Back up configured files before rebuilding a Dev Container, then restore them
after rebuilding. The configuration is devcontainer_state.conf beside this
script. List one absolute path or ~/path per line.

Commands:
  backup [--recreate]    Back up configured paths to the Git workspace
                         Replace an existing backup only with --recreate
  restore                Restore paths from the workspace backup
  -h, --help             Show this help

Large paths over 100 MiB require confirmation. Existing restore targets
require a per-path choice. Interactive confirmation requires a terminal.
EOF
}

_devcontainer_state_workspace_root() {
  local root

  root="$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null)" || {
    log_error "Not inside a Git worktree."
    return 1
  }

  printf '%s\n' "${root}"
}

_devcontainer_state_path_overlaps_backup() {
  local path="$1"
  local backup_dir="$2"

  [[ "${path}" == "${backup_dir}" ||
    "${path}" == "${backup_dir}/"* ||
    "${backup_dir}" == "${path}/"* ]]
}

_devcontainer_state_resolve_path() {
  local configured_path="$1"

  if [[ "${configured_path}" == "~" ]]; then
    if [[ -z "${HOME:-}" ]]; then
      log_error "HOME is not set; cannot resolve: ${configured_path}"
      return 1
    fi
    configured_path="${HOME}"
  elif [[ "${configured_path}" == "~/"* ]]; then
    if [[ -z "${HOME:-}" ]]; then
      log_error "HOME is not set; cannot resolve: ${configured_path}"
      return 1
    fi
    configured_path="${HOME}/${configured_path#\~/}"
  elif [[ "${configured_path}" != /* ]]; then
    log_error "Configured paths must be absolute or start with ~/: ${configured_path}"
    return 1
  fi

  configured_path="${configured_path:a}"
  if [[ "${configured_path}" == "/" ]]; then
    log_error "The filesystem root cannot be a configured path."
    return 1
  fi

  if [[ "${configured_path}" == *$'\t'* ]]; then
    log_error "Configured paths containing tabs are not supported."
    return 1
  fi

  printf '%s\n' "${configured_path}"
}

_devcontainer_state_read_config() {
  local configured_path resolved_path
  local existing_path
  local -a resolved_paths

  if [[ ! -r "${_devcontainer_state_config}" ]]; then
    log_error "Configuration file not found or unreadable: ${_devcontainer_state_config}"
    return 1
  fi

  while IFS= read -r configured_path || [[ -n "${configured_path}" ]]; do
    [[ -z "${configured_path}" || "${configured_path}" == \#* ]] && continue
    resolved_path="$(_devcontainer_state_resolve_path "${configured_path}")" || return 1

    for existing_path in "${resolved_paths[@]}"; do
      if [[ "${existing_path}" == "${resolved_path}" ]]; then
        log_error "Duplicate configured path: ${configured_path}"
        return 1
      fi
    done
    resolved_paths+=("${resolved_path}")
  done < "${_devcontainer_state_config}"

  if (( ${#resolved_paths[@]} == 0 )); then
    log_error "No paths are configured in ${_devcontainer_state_config}"
    return 1
  fi

  _devcontainer_state_paths=("${resolved_paths[@]}")
}

_devcontainer_state_read_tty() {
  local prompt="$1"

  if [[ ! -t 0 && ! -t 1 && ! -t 2 ]] ||
    [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    log_error "Interactive confirmation requires a terminal."
    return 1
  fi

  printf '%s' "${prompt}" >/dev/tty
  IFS= read -r REPLY </dev/tty || {
    log_error "Unable to read confirmation from the terminal."
    return 1
  }
}

_devcontainer_state_backup_confirm() {
  local path="$1"
  local size_kb="$2"

  while true; do
    _devcontainer_state_read_tty \
      "Path exceeds 100 MiB (${size_kb} KiB): ${path}. Back it up? [y/N] " || return 1
    case "${REPLY}" in
      y|Y)
        REPLY="y"
        return 0
        ;;
      n|N|"")
        REPLY="n"
        return 0
        ;;
      *)
        log_warn "Please answer y or n."
        ;;
    esac
  done
}

devcontainer_state_backup() {
  local workspace_root backup_dir staging_dir previous_dir manifest source_path item_id item_dir payload
  local du_output size_kb copied=0 skipped=0 index=0
  local recreate=false
  local -a _devcontainer_state_paths approved_paths

  if (( $# == 1 )) && [[ "$1" == "--recreate" ]]; then
    recreate=true
  elif (( $# != 0 )); then
    log_error "Usage: devcontainer_state_backup [--recreate]"
    return 1
  fi

  _devcontainer_state_read_config || return 1
  workspace_root="$(_devcontainer_state_workspace_root)" || return 1
  backup_dir="${workspace_root}/.devcontainer-state-backup"
  manifest="${backup_dir}/manifest.tsv"

  if [[ -e "${backup_dir}" || -L "${backup_dir}" ]]; then
    if [[ "${recreate}" != true ]]; then
      log_error "A backup already exists: ${backup_dir} (use --recreate to replace it)"
      return 1
    fi
    if [[ ! -d "${backup_dir}" || -L "${backup_dir}" ]]; then
      log_error "Existing backup is not a directory: ${backup_dir}"
      return 1
    fi
  fi

  for source_path in "${_devcontainer_state_paths[@]}"; do
    if _devcontainer_state_path_overlaps_backup "${source_path}" "${backup_dir}"; then
      log_error "Configured path overlaps the workspace backup directory: ${source_path}"
      return 1
    fi

    if [[ ! -e "${source_path}" && ! -L "${source_path}" ]]; then
      log_warn "[skip] configured path does not exist: ${source_path}"
      skipped=$((skipped + 1))
      continue
    fi

    if ! du_output="$(du -sk --apparent-size -- "${source_path}" 2>/dev/null)"; then
      log_error "Unable to measure configured path: ${source_path}"
      return 1
    fi
    size_kb="${du_output%%$'\t'*}"

    if [[ "${size_kb}" != <-> ]]; then
      log_error "Unable to determine the size of: ${source_path}"
      return 1
    fi

    if (( size_kb > 102400 )); then
      _devcontainer_state_backup_confirm "${source_path}" "${size_kb}" || return 1
      if [[ "${REPLY}" != "y" ]]; then
        skipped=$((skipped + 1))
        continue
      fi
    fi
    approved_paths+=("${source_path}")
  done

  if (( ${#approved_paths[@]} == 0 )); then
    log_warn "[partial] backed up 0, skipped ${skipped}"
    return 1
  fi

  staging_dir="$(mktemp -d "${workspace_root}/.devcontainer-state-backup.XXXXXX")" || {
    log_error "Unable to create a temporary backup directory in: ${workspace_root}"
    return 1
  }
  manifest="${staging_dir}/manifest.tsv"
  mkdir -p "${staging_dir}/items" || {
    rm -rf -- "${staging_dir}"
    log_error "Unable to create backup directory: ${staging_dir}"
    return 1
  }
  : > "${manifest}" || {
    rm -rf -- "${staging_dir}"
    log_error "Unable to create backup manifest: ${manifest}"
    return 1
  }

  for source_path in "${approved_paths[@]}"; do
    index=$((index + 1))
    item_id="$(printf '%06d' "${index}")"
    item_dir="${staging_dir}/items/${item_id}"
    payload="${item_dir}/payload"

    mkdir -p "${item_dir}" || {
      rm -rf -- "${staging_dir}"
      log_error "Unable to prepare backup for: ${source_path}"
      return 1
    }

    if ! cp -a -- "${source_path}" "${payload}"; then
      rm -rf -- "${staging_dir}"
      log_error "Unable to back up: ${source_path}"
      return 1
    fi

    if ! printf '%s\t%s\n' "${item_id}" "${source_path}" >> "${manifest}"; then
      rm -rf -- "${staging_dir}"
      log_error "Unable to record backup for: ${source_path}"
      return 1
    fi

    log_success "[backup] ${source_path}"
    copied=$((copied + 1))
  done

  if (( copied == 0 )); then
    rm -rf -- "${staging_dir}"
    log_warn "[partial] backed up 0, skipped ${skipped}"
    return 1
  fi

  if [[ ( -e "${backup_dir}" || -L "${backup_dir}" ) && "${recreate}" != true ]]; then
    rm -rf -- "${staging_dir}"
    log_error "A backup appeared during this operation: ${backup_dir}"
    return 1
  fi

  if [[ -e "${backup_dir}" || -L "${backup_dir}" ]]; then
    previous_dir="$(mktemp -d "${workspace_root}/.devcontainer-state-backup.previous.XXXXXX")" || {
      rm -rf -- "${staging_dir}"
      log_error "Unable to prepare replacement of existing backup."
      return 1
    }
    rmdir "${previous_dir}" || {
      rm -rf -- "${staging_dir}" "${previous_dir}"
      log_error "Unable to prepare replacement of existing backup."
      return 1
    }
    if ! mv -- "${backup_dir}" "${previous_dir}"; then
      rm -rf -- "${staging_dir}"
      log_error "Unable to move existing backup out of the way: ${backup_dir}"
      return 1
    fi
  fi

  if ! mv -- "${staging_dir}" "${backup_dir}"; then
    if [[ -n "${previous_dir}" ]]; then
      mv -- "${previous_dir}" "${backup_dir}" ||
        log_error "Unable to restore the previous backup: ${backup_dir}"
    fi
    rm -rf -- "${staging_dir}"
    log_error "Unable to install new backup: ${backup_dir}"
    return 1
  fi

  if [[ -n "${previous_dir}" ]] && ! rm -rf -- "${previous_dir}"; then
    log_error "New backup was created, but the previous backup could not be removed: ${previous_dir}"
    return 1
  fi

  if (( skipped > 0 )); then
    log_warn "[partial] backed up ${copied}, skipped ${skipped}"
    return 1
  fi

  log_done "[done] backed up ${copied} configured path(s)"
}

_devcontainer_state_restore_choice() {
  local path="$1"

  if [[ ! -t 0 && ! -t 1 && ! -t 2 ]] ||
    [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    log_error "Interactive confirmation requires a terminal."
    return 1
  fi

  while true; do
    printf 'Target exists: %s\n' "${path}" >/dev/tty
    _devcontainer_state_read_tty \
      "[s]kip, [o]verwrite, [S]kip all, [O]verwrite all, [q]uit: " || return 1
    case "${REPLY}" in
      s|o|S|O|q)
        return 0
        ;;
      *)
        log_warn "Choose s, o, S, O, or q."
        ;;
    esac
  done
}

_devcontainer_state_remove_manifest_entry() {
  local manifest="$1"
  local item_id="$2"
  local temporary_manifest

  temporary_manifest="$(mktemp "${manifest}.XXXXXX")" || {
    log_error "Unable to prepare manifest update."
    return 1
  }

  if ! awk -F '\t' -v id="${item_id}" '$1 != id' "${manifest}" > "${temporary_manifest}"; then
    rm -f -- "${temporary_manifest}"
    log_error "Unable to update backup manifest."
    return 1
  fi

  if ! mv -- "${temporary_manifest}" "${manifest}"; then
    rm -f -- "${temporary_manifest}"
    log_error "Unable to save backup manifest."
    return 1
  fi
}

_devcontainer_state_restore_one() {
  local backup_dir="$1"
  local item_id="$2"
  local target_path="$3"
  local payload
  local stage_dir staged_path replaced_path=""
  local had_target=false

  payload="${backup_dir}/items/${item_id}/payload"
  if [[ ! -e "${payload}" && ! -L "${payload}" ]]; then
    log_error "Backup data is missing for: ${target_path}"
    return 1
  fi

  replaced_path="${backup_dir}/replaced/${item_id}"
  if [[ -e "${replaced_path}" || -L "${replaced_path}" ]]; then
    log_error "A previous target backup needs attention: ${replaced_path}"
    return 1
  fi

  mkdir -p -- "${target_path:h}" || {
    log_error "Unable to create target directory: ${target_path:h}"
    return 1
  }

  stage_dir="$(mktemp -d "${target_path:h}/.devcontainer-state.XXXXXX")" || {
    log_error "Unable to prepare restore for: ${target_path}"
    return 1
  }
  staged_path="${stage_dir}/${target_path:t}"

  if ! cp -a -- "${payload}" "${staged_path}"; then
    rm -rf -- "${stage_dir}"
    log_error "Unable to prepare restored data for: ${target_path}"
    return 1
  fi

  if [[ -e "${target_path}" || -L "${target_path}" ]]; then
    mkdir -p "${replaced_path:h}" || {
      rm -rf -- "${stage_dir}"
      log_error "Unable to prepare replacement for: ${target_path}"
      return 1
    }
    if ! mv -- "${target_path}" "${replaced_path}"; then
      rm -rf -- "${stage_dir}"
      log_error "Unable to move existing target out of the way: ${target_path}"
      return 1
    fi
    had_target=true
  fi

  if ! mv -- "${staged_path}" "${target_path}"; then
    if [[ "${had_target}" == true ]]; then
      mv -- "${replaced_path}" "${target_path}" ||
        log_error "Unable to restore the previous target: ${target_path}"
    fi
    rm -rf -- "${stage_dir}"
    log_error "Unable to install restored data at: ${target_path}"
    return 1
  fi

  rmdir "${stage_dir}" 2>/dev/null

  if [[ "${had_target}" == true ]] && ! rm -rf -- "${replaced_path}"; then
    log_error "Restored data, but could not remove the replaced target backup: ${replaced_path}"
    return 1
  fi

  _devcontainer_state_remove_manifest_entry \
    "${backup_dir}/manifest.tsv" "${item_id}" || return 1
  rm -rf -- "${backup_dir}/items/${item_id}" || {
    log_error "Restored data, but could not remove its backup: ${target_path}"
    return 1
  }

  log_success "[restore] ${target_path}"
}

devcontainer_state_restore() {
  local workspace_root backup_dir manifest item_id target_path choice manifest_line
  local always_skip=false always_overwrite=false restored=0 skipped=0 failed=0
  local -a item_ids target_paths
  local -i index

  if (( $# != 0 )); then
    log_error "Usage: devcontainer_state_restore"
    return 1
  fi

  workspace_root="$(_devcontainer_state_workspace_root)" || return 1
  backup_dir="${workspace_root}/.devcontainer-state-backup"
  manifest="${backup_dir}/manifest.tsv"

  if [[ ! -d "${backup_dir}" || -L "${backup_dir}" || ! -r "${manifest}" ]]; then
    log_error "No usable backup found at: ${backup_dir}"
    return 1
  fi

  while IFS= read -r manifest_line || [[ -n "${manifest_line}" ]]; do
    item_id="${manifest_line%%$'\t'*}"
    target_path="${manifest_line#*$'\t'}"
    if [[ "${item_id}" != <-> || -z "${target_path}" || "${target_path}" != /* ]]; then
      log_error "Invalid backup manifest entry."
      return 1
    fi
    target_path="$(_devcontainer_state_resolve_path "${target_path}")" || return 1
    if _devcontainer_state_path_overlaps_backup "${target_path}" "${backup_dir}"; then
      log_error "Backup target overlaps the workspace backup directory: ${target_path}"
      return 1
    fi
    item_ids+=("${item_id}")
    target_paths+=("${target_path}")
  done < "${manifest}"

  if (( ${#item_ids[@]} == 0 )); then
    log_error "Backup manifest contains no restorable paths."
    return 1
  fi

  for (( index = 1; index <= ${#item_ids[@]}; index++ )); do
    item_id="${item_ids[index]}"
    target_path="${target_paths[index]}"

    if [[ -e "${target_path}" || -L "${target_path}" ]]; then
      if [[ "${always_skip}" == true ]]; then
        choice="s"
      elif [[ "${always_overwrite}" == true ]]; then
        choice="o"
      else
        _devcontainer_state_restore_choice "${target_path}" || {
          failed=$((failed + 1))
          break
        }
        choice="${REPLY}"
      fi

      case "${choice}" in
        s)
          log_warn "[skip] ${target_path}"
          skipped=$((skipped + 1))
          continue
          ;;
        S)
          always_skip=true
          log_warn "[skip] ${target_path}"
          skipped=$((skipped + 1))
          continue
          ;;
        O)
          always_overwrite=true
          choice="o"
          ;;
        q)
          log_warn "Restore cancelled; remaining backups were kept."
          failed=$((failed + 1))
          break
          ;;
      esac
    fi

    if _devcontainer_state_restore_one "${backup_dir}" "${item_id}" "${target_path}"; then
      restored=$((restored + 1))
    else
      failed=$((failed + 1))
    fi
  done

  if [[ ! -s "${manifest}" ]]; then
    if ! rm -rf -- "${backup_dir}"; then
      log_error "All paths were restored, but the backup directory could not be removed: ${backup_dir}"
      return 1
    fi
  fi

  if (( failed > 0 || skipped > 0 )); then
    log_warn "[partial] restored ${restored}, skipped ${skipped}, failed ${failed}"
    return 1
  fi

  log_done "[done] restored ${restored} configured path(s)"
}

_devcontainer_state_main() {
  local command="${1:-}"

  if [[ -z "${command}" ]]; then
    _devcontainer_state_help >&2
    return 1
  fi
  shift

  case "${command}" in
    backup)
      devcontainer_state_backup "$@"
      ;;
    restore)
      devcontainer_state_restore "$@"
      ;;
    -h|--help)
      _devcontainer_state_help
      ;;
    *)
      log_error "Unknown command: ${command}"
      _devcontainer_state_help >&2
      return 1
      ;;
  esac
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  _devcontainer_state_main "$@"
fi
