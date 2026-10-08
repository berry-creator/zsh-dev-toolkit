#!/usr/bin/env zsh

_codex_tools_dir="${${(%):-%N}:A:h}"
. "${_codex_tools_dir}/logging.zsh"
unset _codex_tools_dir

_codex_tools_ensure_config_file() {
  mkdir -p ~/.codex
  touch ~/.codex/config.toml
  if [ ! -s ~/.codex/config.toml ]; then
    printf '\n' > ~/.codex/config.toml
  fi
}

_codex_tools_toml_string() {
  printf '%s' "$1" | perl -pe 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g;'
}

codex_tools_configure_custom_provider() {
  local openai_base_url="${1:-}"

  if (( $# != 1 )) || [ -z "${openai_base_url}" ]; then
    log_error "Usage: codex_tools_configure_custom_provider <openai_base_url>"
    return 1
  fi

  _codex_tools_ensure_config_file

  perl -0pi -e '
    s/^# BEGIN configure_codex\n.*?^# END configure_codex\n{0,2}//msg;
    s/^(model|model_reasoning_effort|approval_policy|sandbox_mode|allow_login_shell|requires_openai_auth|model_provider)\s*=.*\n//mg;
    s/^\[model_providers\.custom\]\n(?:(?!^\[).*\n)*//mg;
  ' ~/.codex/config.toml

  local codex_base_config
  codex_base_config="$(cat <<EOF
# BEGIN configure_codex
model = "gpt-6.1-sol"
model_reasoning_effort = "medium"

approval_policy = "never"
sandbox_mode = "danger-full-access"

allow_login_shell = false
requires_openai_auth = false

model_provider = "custom"

[model_providers.custom]
name = "custom"
base_url = "${openai_base_url}"
env_key = "OPENAI_API_KEY"
# END configure_codex
EOF
)"

  CODEX_BASE_CONFIG="${codex_base_config}" perl -0pi -e '
    s/\A/$ENV{CODEX_BASE_CONFIG}\n\n/s;
  ' ~/.codex/config.toml

  log_success "Configuration has written to ~/.codex/config.toml"
}

codex_tools_trust_project() {
  local project_path="${1:-}"
  local project_key

  if (( $# != 1 )) || [ -z "${project_path}" ]; then
    log_error "Usage: codex_tools_trust_project <project_path>"
    return 1
  fi

  _codex_tools_ensure_config_file
  project_key="$(_codex_tools_toml_string "${project_path}")"

  CODEX_PROJECT_KEY="${project_key}" perl -0pi -e '
    my $key = quotemeta($ENV{CODEX_PROJECT_KEY});
    s/^\[projects\."$key"\]\n(?:(?!^\[).*\n)*\n?//mg;
  ' ~/.codex/config.toml

  {
    echo ""
    echo "[projects.\"${project_key}\"]"
    echo "trust_level = \"trusted\""
  } >> ~/.codex/config.toml

  log_success "Trusted Codex project '${project_path}' in ~/.codex/config.toml"
}

codex_tools_setup_mysql_mcp() {
  local server_name="${1:-}"
  local mysql_host="${2:-}"
  local mysql_port="${3:-}"
  local mysql_user="${4:-}"
  local mysql_password="${5:-}"
  local mysql_database="${6:-}"

  if (( $# != 6 )) ||
    [ -z "${server_name}" ] ||
    [ -z "${mysql_host}" ] ||
    [ -z "${mysql_port}" ] ||
    [ -z "${mysql_user}" ] ||
    [ -z "${mysql_password}" ] ||
    [ -z "${mysql_database}" ]; then
    log_error "Usage: codex_tools_setup_mysql_mcp <server_name> <host> <port> <user> <password> <database>"
    return 1
  fi

  npm install -g mysql-mcp-server || return 1

  local mysql_mcp_command
  mysql_mcp_command="$(command -v mysql-mcp-server)"
  if [ -z "${mysql_mcp_command}" ]; then
    log_error "mysql-mcp-server was installed, but it is not available in PATH"
    return 1
  fi

  _codex_tools_ensure_config_file

  SERVER_NAME="${server_name}" perl -0pi -e '
    my $name = quotemeta($ENV{SERVER_NAME});
    s/^# BEGIN setup_mysql_mcp $name\n.*?^# END setup_mysql_mcp $name\n{0,2}//msg;
    s/^# BEGIN setup_codex_mysql_mcp $name\n.*?^# END setup_codex_mysql_mcp $name\n{0,2}//msg;
    s/^# BEGIN codex_tools_setup_mysql_mcp $name\n.*?^# END codex_tools_setup_mysql_mcp $name\n{0,2}//msg;
    s/^\[mcp_servers\.$name(?:\.env)?\]\n(?:(?!^\[).*\n)*//mg;
  ' ~/.codex/config.toml

  {
    echo ""
    echo "# BEGIN codex_tools_setup_mysql_mcp ${server_name}"
    echo "[mcp_servers.${server_name}]"
    echo "command = \"${mysql_mcp_command}\""
    echo ""
    echo "[mcp_servers.${server_name}.env]"
    echo "MYSQL_HOST = \"${mysql_host}\""
    echo "MYSQL_PORT = \"${mysql_port}\""
    echo "MYSQL_USER = \"${mysql_user}\""
    echo "MYSQL_PASSWORD = \"${mysql_password}\""
    echo "MYSQL_DATABASE = \"${mysql_database}\""
    echo "# END codex_tools_setup_mysql_mcp ${server_name}"
  } >> ~/.codex/config.toml

  log_success "Configured MCP server '${server_name}' in ~/.codex/config.toml"
  log_info "Restart Codex to load the new MCP server."
}

codex_tools_help() {
  cat <<'EOF'
Usage: codex_tools.zsh <command> [arguments...]
       . /path/to/codex_tools.zsh

Commands:
  configure-custom-provider <openai_base_url>
  trust-project <project_path>
  setup-mysql-mcp <server_name> <host> <port> <user> <password> <database>

Source this script to load the corresponding codex_tools_* functions and
codex_tools_help into the current zsh process.
EOF
}

_codex_tools_main() {
  local command="${1:-}"

  if [ -z "${command}" ]; then
    codex_tools_help >&2
    return 1
  fi
  shift

  case "${command}" in
    configure-custom-provider)
      codex_tools_configure_custom_provider "$@"
      ;;
    trust-project)
      codex_tools_trust_project "$@"
      ;;
    setup-mysql-mcp)
      codex_tools_setup_mysql_mcp "$@"
      ;;
    -h|--help)
      codex_tools_help
      ;;
    *)
      log_error "Unknown Codex tools command: ${command}"
      codex_tools_help >&2
      return 1
      ;;
  esac
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  _codex_tools_main "$@"
fi
