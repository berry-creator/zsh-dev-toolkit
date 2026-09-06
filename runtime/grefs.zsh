#!/usr/bin/env zsh

_grefs_dir="${${(%):-%N}:A:h}"
. "${_grefs_dir}/logging.zsh"
unset _grefs_dir

grefs() {
  local scope="heads"
  local ahead_only=0
  local behind_only=0
  local same_only=0
  local arg line
  local short_ref full_ref object_name author_name commit_date subject
  local base counts behind ahead compare_cols has_ahead has_behind all_same sort_key
  local sort_spec="date:desc"
  local sort_col="date"
  local sort_dir="desc"
  local -a bases keywords ref_roots sort_args

  bases=("main")
  keywords=()

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "${arg}" in
      -r)
        scope="remotes"
        ;;
      -a)
        scope="all"
        ;;
      -b)
        shift
        if [ "$#" -eq 0 ] || [ -z "$1" ]; then
          log_error "grefs: -b requires a branch or ref"
          return 1
        fi
        bases=("$1")
        ;;
      -s|--sort)
        shift
        if [ "$#" -eq 0 ] || [ -z "$1" ]; then
          log_error "grefs: --sort requires column[:asc|desc]"
          return 1
        fi
        sort_spec="${1:l}"
        ;;
      --ahead)
        ahead_only=1
        ;;
      --behind)
        behind_only=1
        ;;
      --same)
        same_only=1
        ;;
      -h|--help)
        cat <<'EOF'
Usage: grefs [options] [keyword...]

List Git refs with commit metadata and ahead/behind counts.

Options:
  -r                     List remote refs only
  -a                     List local and remote refs
  -b <ref>               Compare against <ref> instead of main
  -s, --sort <sort>      Sort by column[:direction]
  --ahead                Show only refs ahead of the compare ref
  --behind               Show only refs behind the compare ref
  --same                 Show only refs with no ahead/behind difference
  -h, --help             Show this help

Sort columns:
  ref                    Sort by REF
  author                 Sort by AUTHOR
  date                   Sort by DATE
  ahead                  Sort by ahead count numerically
  behind                 Sort by behind count numerically

Sort directions:
  asc                    Ascending order
  desc                   Descending order

Examples:
  grefs
  grefs --sort ref
  grefs --sort date:desc
  grefs -s ahead:desc
  grefs -b origin/main --sort behind:desc
EOF
        return 0
        ;;
      --)
        shift
        keywords+=("$@")
        break
        ;;
      -*)
        log_error "grefs: unknown option: ${arg}"
        return 1
        ;;
      *)
        keywords+=("${arg}")
        ;;
    esac
    shift
  done

  if [[ "${sort_spec}" == *:* ]]; then
    sort_col="${sort_spec%%:*}"
    sort_dir="${sort_spec#*:}"
  else
    sort_col="${sort_spec}"
    sort_dir="asc"
  fi

  case "${sort_col}" in
    ref|author|date|ahead|behind)
      ;;
    *)
      log_error "grefs: unsupported sort column: ${sort_col}"
      return 1
      ;;
  esac

  case "${sort_dir}" in
    asc)
      sort_args=()
      ;;
    desc)
      sort_args=(-r)
      ;;
    *)
      log_error "grefs: unsupported sort direction: ${sort_dir}"
      return 1
      ;;
  esac

  case "${sort_col}" in
    ahead|behind)
      sort_args=(-n "${sort_args[@]}")
      ;;
  esac

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    log_error "grefs: not inside a Git repository"
    return 1
  fi

  for base in "${bases[@]}"; do
    if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
      log_error "grefs: compare ref not found: ${base}"
      return 1
    fi
  done

  case "${scope}" in
    heads)
      ref_roots=(refs/heads)
      ;;
    remotes)
      ref_roots=(refs/remotes)
      ;;
    all)
      ref_roots=(refs/heads refs/remotes)
      ;;
  esac

  printf '%-30s | %-7s | %-10s | %-10s | %-18s | %s\n' "REF" "HASH" "AUTHOR" "DATE" "AHEAD/BEHIND" "SUBJECT"
  printf '%s\n' "------------------------------ | ------- | ---------- | ---------- | ------------------ | -------"

  git for-each-ref \
    --sort=-committerdate \
    --format=$'%(refname:short)\t%(refname)\t%(objectname:short)\t%(authorname)\t%(committerdate:short)\t%(subject)' \
    "${ref_roots[@]}" |
    while IFS=$'\t' read -r short_ref full_ref object_name author_name commit_date subject; do
      if [[ "${full_ref}" == refs/remotes/*/HEAD ]]; then
        continue
      fi

      compare_cols=""
      has_ahead=0
      has_behind=0
      all_same=1

      for base in "${bases[@]}"; do
        counts="$(git rev-list --left-right --count "${base}...${short_ref}" 2>/dev/null)" || continue
        behind="${counts%%[[:space:]]*}"
        ahead="${counts##*[[:space:]]}"

        if [ "${ahead}" -gt 0 ]; then
          has_ahead=1
          all_same=0
        fi
        if [ "${behind}" -gt 0 ]; then
          has_behind=1
          all_same=0
        fi

        compare_cols="${compare_cols} | $(printf '%-18s' "${base} +${ahead}/-${behind}")"
      done

      if [ "${ahead_only}" -eq 1 ] && [ "${has_ahead}" -eq 0 ]; then
        continue
      fi
      if [ "${behind_only}" -eq 1 ] && [ "${has_behind}" -eq 0 ]; then
        continue
      fi
      if [ "${same_only}" -eq 1 ] && [ "${all_same}" -eq 0 ]; then
        continue
      fi

      line="$(printf '%-30s | %-7s | %-10s | %-10s%s | %s' "${short_ref}" "${object_name}" "${author_name}" "${commit_date}" "${compare_cols}" "${subject}")"

      for arg in "${keywords[@]}"; do
        if ! printf '%s\n' "${line}" | grep -i -- "${arg}" >/dev/null; then
          line=""
          break
        fi
      done

      if [ -n "${line}" ]; then
        case "${sort_col}" in
          ref)
            sort_key="${short_ref}"
            ;;
          author)
            sort_key="${author_name}"
            ;;
          date)
            sort_key="${commit_date}"
            ;;
          ahead)
            sort_key="${ahead}"
            ;;
          behind)
            sort_key="${behind}"
            ;;
        esac
        printf '%s\t%s\n' "${sort_key}" "${line}"
      fi
    done |
    sort -s "${sort_args[@]}" -k1,1 |
    cut -f2-
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  grefs "$@"
fi
