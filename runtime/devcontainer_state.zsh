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
script. List one absolute path or ~/path per line. Optional tab-separated
fields after the path are GNU tar exclusion patterns.

Commands:
  backup [--recreate]    Back up configured paths to the Git workspace
                         Replace an existing backup only with --recreate
  restore                Restore paths from the workspace backup
  -h, --help             Show this help

Large paths over 100 MiB require confirmation. Existing restore targets
require a per-path choice. GNU tar is required. Backups are sparse tar.gz
archives with ACL and extended-attribute support. Interactive confirmation
requires a terminal.
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

_devcontainer_state_require_gnu_tar() {
  local version

  if ! command -v tar >/dev/null 2>&1; then
    log_error "GNU tar is required for Dev Container state backups."
    return 1
  fi

  version="$(tar --version 2>/dev/null)" || {
    log_error "Unable to determine the tar implementation."
    return 1
  }
  if [[ "${version}" != "tar (GNU tar)"* ]]; then
    log_error "GNU tar is required for Dev Container state backups."
    return 1
  fi
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
  local config_line configured_path resolved_path existing_path remainder pattern more_fields
  local exclude_offset
  local -a resolved_paths resolved_exclude_patterns resolved_exclude_counts
  local -a resolved_exclude_offsets line_exclude_patterns

  if [[ ! -r "${_devcontainer_state_config}" ]]; then
    log_error "Configuration file not found or unreadable: ${_devcontainer_state_config}"
    return 1
  fi

  while IFS= read -r config_line || [[ -n "${config_line}" ]]; do
    [[ -z "${config_line}" || "${config_line}" == \#* ]] && continue
    configured_path="${config_line%%$'\t'*}"
    resolved_path="$(_devcontainer_state_resolve_path "${configured_path}")" || return 1
    line_exclude_patterns=()

    if [[ "${config_line}" == *$'\t'* ]]; then
      remainder="${config_line#*$'\t'}"
      while true; do
        if [[ "${remainder}" == *$'\t'* ]]; then
          pattern="${remainder%%$'\t'*}"
          remainder="${remainder#*$'\t'}"
          more_fields=true
        else
          pattern="${remainder}"
          more_fields=false
        fi

        if [[ -z "${pattern}" ]]; then
          log_error "Empty exclusion pattern for: ${configured_path}"
          return 1
        fi
        line_exclude_patterns+=("${pattern}")
        [[ "${more_fields}" == true ]] || break
      done
    fi

    for existing_path in "${resolved_paths[@]}"; do
      if [[ "${existing_path}" == "${resolved_path}" ]]; then
        log_error "Duplicate configured path: ${configured_path}"
        return 1
      fi
    done
    resolved_paths+=("${resolved_path}")
    resolved_exclude_counts+=("${#line_exclude_patterns[@]}")
    exclude_offset=$(( ${#resolved_exclude_patterns[@]} + 1 ))
    resolved_exclude_offsets+=("${exclude_offset}")
    resolved_exclude_patterns+=("${line_exclude_patterns[@]}")
  done < "${_devcontainer_state_config}"

  if (( ${#resolved_paths[@]} == 0 )); then
    log_error "No paths are configured in ${_devcontainer_state_config}"
    return 1
  fi

  _devcontainer_state_paths=("${resolved_paths[@]}")
  _devcontainer_state_exclude_counts=("${resolved_exclude_counts[@]}")
  _devcontainer_state_exclude_offsets=("${resolved_exclude_offsets[@]}")
  _devcontainer_state_exclude_patterns=("${resolved_exclude_patterns[@]}")
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
  local workspace_root backup_dir staging_dir previous_dir manifest source_path item_id payload
  local du_output size_kb copied=0 skipped=0 index=0 exclude_count exclude_offset pattern_index path_index
  local recreate=false
  local -a _devcontainer_state_paths _devcontainer_state_exclude_counts _devcontainer_state_exclude_offsets
  local -a _devcontainer_state_exclude_patterns approved_path_indexes tar_excludes

  if (( $# == 1 )) && [[ "$1" == "--recreate" ]]; then
    recreate=true
  elif (( $# != 0 )); then
    log_error "Usage: devcontainer_state_backup [--recreate]"
    return 1
  fi

  _devcontainer_state_read_config || return 1
  workspace_root="$(_devcontainer_state_workspace_root)" || return 1
  _devcontainer_state_require_gnu_tar || return 1
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

  for (( path_index = 1; path_index <= ${#_devcontainer_state_paths[@]}; path_index++ )); do
    source_path="${_devcontainer_state_paths[path_index]}"

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
    approved_path_indexes+=("${path_index}")
  done

  if (( skipped > 0 )) &&
    [[ "${recreate}" == true && ( -e "${backup_dir}" || -L "${backup_dir}" ) ]]; then
    log_error "Incomplete replacement; the existing backup was left unchanged."
    return 1
  fi

  if (( ${#approved_path_indexes[@]} == 0 )); then
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

  for path_index in "${approved_path_indexes[@]}"; do
    source_path="${_devcontainer_state_paths[path_index]}"
    index=$((index + 1))
    item_id="$(printf '%06d' "${index}")"
    payload="${staging_dir}/items/${item_id}.tar.gz"
    exclude_count="${_devcontainer_state_exclude_counts[path_index]}"
    exclude_offset="${_devcontainer_state_exclude_offsets[path_index]}"
    tar_excludes=()
    for (( pattern_index = exclude_offset; pattern_index < exclude_offset + exclude_count; pattern_index++ )); do
      tar_excludes+=("--exclude=${_devcontainer_state_exclude_patterns[pattern_index]}")
    done

    if ! tar --create --gzip --file="${payload}" --sparse --acls --xattrs \
      "${tar_excludes[@]}" \
      --directory="${source_path:h}" -- "${source_path:t}"; then
      rm -rf -- "${staging_dir}"
      log_error "Unable to prepare backup for: ${source_path}"
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
  local archive="${backup_dir}/items/${item_id}.tar.gz"
  local legacy_payload="${backup_dir}/items/${item_id}/payload"
  local legacy_archive=""
  local item_backup="${backup_dir}/items/${item_id}"
  local stage_dir staged_path replaced_dir replaced_path expected_entry cleanup_dir cleanup_item original_item
  local legacy=false
  local -a staged_entries
  local had_target=false

  if [[ -e "${archive}" || -L "${archive}" ]]; then
    if [[ ! -f "${archive}" || -L "${archive}" ]]; then
      log_error "Backup archive is invalid for: ${target_path}"
      return 1
    fi
    if ! tar --list --gzip --file="${archive}" >/dev/null; then
      log_error "Backup archive is corrupt or unreadable for: ${target_path}"
      return 1
    fi
    expected_entry="${target_path:t}"
  elif [[ -e "${legacy_payload}" || -L "${legacy_payload}" ]]; then
    legacy_archive="$(mktemp "${backup_dir}/.legacy-${item_id}.XXXXXX")" || {
      log_error "Unable to prepare legacy backup for: ${target_path}"
      return 1
    }
    archive="${legacy_archive}"
    legacy=true
    if ! tar --create --gzip --file="${archive}" --sparse --acls --xattrs \
      --directory="${legacy_payload:h}" -- "${legacy_payload:t}"; then
      rm -f -- "${archive}"
      log_error "Unable to prepare legacy backup for: ${target_path}"
      return 1
    fi
    if ! tar --list --gzip --file="${archive}" >/dev/null; then
      rm -f -- "${archive}"
      log_error "Legacy backup is corrupt or unreadable for: ${target_path}"
      return 1
    fi
    expected_entry="${legacy_payload:t}"
  else
    log_error "Backup archive is missing for: ${target_path}"
    return 1
  fi

  mkdir -p -- "${target_path:h}" || {
    [[ "${legacy}" == true ]] && rm -f -- "${archive}"
    log_error "Unable to create target directory: ${target_path:h}"
    return 1
  }

  stage_dir="$(mktemp -d "${target_path:h}/.devcontainer-state.XXXXXX")" || {
    [[ "${legacy}" == true ]] && rm -f -- "${archive}"
    log_error "Unable to prepare restore for: ${target_path}"
    return 1
  }

  if ! tar --extract --gzip --file="${archive}" --sparse --acls --xattrs \
    --no-same-owner --same-permissions --directory="${stage_dir}"; then
    rm -rf -- "${stage_dir}"
    [[ "${legacy}" == true ]] && rm -f -- "${archive}"
    log_error "Unable to prepare restored data for: ${target_path}"
    return 1
  fi
  if [[ "${legacy}" == true ]] && ! rm -f -- "${archive}"; then
    rm -rf -- "${stage_dir}"
    log_error "Unable to remove temporary legacy archive: ${archive}"
    return 1
  fi

  staged_entries=("${stage_dir}"/*(DN))
  if (( ${#staged_entries[@]} != 1 )) ||
    [[ "${staged_entries[1]:t}" != "${expected_entry}" ]]; then
    rm -rf -- "${stage_dir}"
    [[ "${legacy}" == true ]] && rm -f -- "${archive}"
    log_error "Backup archive contains unexpected paths for: ${target_path}"
    return 1
  fi
  staged_path="${staged_entries[1]}"

  if [[ -e "${target_path}" || -L "${target_path}" ]]; then
    replaced_dir="$(mktemp -d "${target_path:h}/.devcontainer-state-replaced.XXXXXX")" || {
      rm -rf -- "${stage_dir}"
      [[ "${legacy}" == true ]] && rm -f -- "${archive}"
      log_error "Unable to prepare replacement for: ${target_path}"
      return 1
    }
    replaced_path="${replaced_dir}/target"
    if ! mv -- "${target_path}" "${replaced_path}"; then
      rm -rf -- "${stage_dir}" "${replaced_dir}"
      [[ "${legacy}" == true ]] && rm -f -- "${archive}"
      log_error "Unable to move existing target out of the way: ${target_path}"
      return 1
    fi
    had_target=true
  fi

  if ! mv -- "${staged_path}" "${target_path}"; then
    if [[ "${had_target}" == true ]]; then
      if ! mv -- "${replaced_path}" "${target_path}"; then
        log_error "Unable to restore the previous target: ${target_path}"
        log_error "The previous target was retained at: ${replaced_path}"
        [[ "${legacy}" == true ]] && rm -f -- "${archive}"
        return 1
      fi
    fi
    rm -rf -- "${stage_dir}" "${replaced_dir}"
    [[ "${legacy}" == true ]] && rm -f -- "${archive}"
    log_error "Unable to install restored data at: ${target_path}"
    return 1
  fi

  if ! rm -rf -- "${stage_dir}"; then
    log_error "Restored data, but could not remove temporary restore data: ${stage_dir}"
    [[ "${legacy}" == true ]] && rm -f -- "${archive}"
    return 1
  fi
  if [[ -n "${replaced_dir}" ]] && ! rm -rf -- "${replaced_dir}"; then
    log_error "Restored data, but could not remove the previous target at: ${replaced_dir}"
    [[ "${legacy}" == true ]] && rm -f -- "${archive}"
    return 1
  fi

  cleanup_dir="$(mktemp -d "${backup_dir}/.restored-${item_id}.XXXXXX")" || {
    log_error "Restored data, but could not prepare backup cleanup: ${target_path}"
    return 1
  }
  cleanup_item="${cleanup_dir}/item"
  if [[ "${legacy}" == true ]]; then
    original_item="${item_backup}"
  else
    original_item="${archive}"
  fi

  if ! mv -- "${original_item}" "${cleanup_item}"; then
    rmdir "${cleanup_dir}" 2>/dev/null
    log_error "Restored data, but could not stage its backup for cleanup: ${target_path}"
    return 1
  fi

  if ! _devcontainer_state_remove_manifest_entry \
    "${backup_dir}/manifest.tsv" "${item_id}"; then
    if ! mv -- "${cleanup_item}" "${original_item}"; then
      log_error "Could not return backup data to its original location: ${original_item}"
    fi
    rmdir "${cleanup_dir}" 2>/dev/null
    return 1
  fi

  if ! rm -rf -- "${cleanup_dir}"; then
    log_warn "Restored data, but could not remove temporary backup cleanup data: ${cleanup_dir}"
  fi

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
  _devcontainer_state_require_gnu_tar || return 1
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
