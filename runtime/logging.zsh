#!/usr/bin/env zsh

_log_color_enabled() {
  [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]
}

_log_indent() {
  local level="${LOG_INDENT_LEVEL:-0}"

  [[ "${level}" == <-> ]] || level=0
  printf '%*s' $((level * 2)) ""
}

_log_message() {
  local color="$1"
  local level="$2"
  local reset=""
  local indent="$(_log_indent)"
  shift 2

  if _log_color_enabled; then
    reset=$'\e[0m'
  else
    color=""
  fi

  printf '%s%s[%s]%s %s\n' "${indent}" "${color}" "${level}" "${reset}" "$*" >&2
}

log_info() {
  _log_message $'\e[34m' "INFO" "$@"
}

log_success() {
  _log_message $'\e[32m' " OK " "$@"
}

log_warn() {
  _log_message $'\e[33m' "WARN" "$@"
}

log_error() {
  _log_message $'\e[31m' "FAIL" "$@"
}

log_section() {
  local color=""
  local reset=""
  local indent="$(_log_indent)"

  if _log_color_enabled; then
    color=$'\e[36m'
    reset=$'\e[0m'
  fi

  printf '%s%s==>%s %s\n' "${indent}" "${color}" "${reset}" "$*" >&2
}

log_done() {
  local color=""
  local reset=""
  local indent="$(_log_indent)"

  if _log_color_enabled; then
    color=$'\e[32m'
    reset=$'\e[0m'
  fi

  printf '%s%s<==%s %s\n' "${indent}" "${color}" "${reset}" "$*" >&2
}

log_blank() {
  printf '\n' >&2
}

log_run_nested() (
  local level="${LOG_INDENT_LEVEL:-0}"

  if (( $# == 0 )); then
    log_error "Usage: log_run_nested <command> [arguments...]"
    return 1
  fi

  [[ "${level}" == <-> ]] || level=0
  export LOG_INDENT_LEVEL=$((level + 1))
  "$@"
)

logging_help() {
  cat <<'EOF'
Usage: logging.zsh <info|success|warn|error|section|done|blank> [message...]
       . /path/to/logging.zsh

Run a logging command, or source this script to load the corresponding log_*
functions and logging_help into the current zsh process.

Source-only helper:
  log_run_nested <command> [arguments...]
                         Run a child command with one additional log indent
EOF
}

_logging_main() {
  local command="${1:-}"

  if [ -z "${command}" ]; then
    logging_help >&2
    return 1
  fi
  shift

  case "${command}" in
    info)
      log_info "$@"
      ;;
    success)
      log_success "$@"
      ;;
    warn)
      log_warn "$@"
      ;;
    error)
      log_error "$@"
      ;;
    section)
      log_section "$@"
      ;;
    done)
      log_done "$@"
      ;;
    blank)
      if [ "$#" -ne 0 ]; then
        logging_help >&2
        return 1
      fi
      log_blank
      ;;
    -h|--help)
      logging_help
      ;;
    *)
      log_error "Unknown logging command: ${command}"
      logging_help >&2
      return 1
      ;;
  esac
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  _logging_main "$@"
fi
