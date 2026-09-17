# shellcheck shell=bash
# Install a stub gh on PATH for tests.

MOCK_GH_DIR=""
_ORIG_PATH=""

install_mock_gh() {
  _ORIG_PATH="$PATH"
  MOCK_GH_DIR="$(mktemp -d)"
  cat >"$MOCK_GH_DIR/gh" <<'MOCK_EOF'
#!/usr/bin/env bash
set -uo pipefail

cmd="${1:-}"
shift || true

case "$cmd" in
  repo)
    if [[ "${1:-}" == "view" ]]; then
      exit "${MOCK_REPO_VIEW_EXIT:-0}"
    fi
    if [[ "${1:-}" == "create" ]]; then
      shift || true
      spec="${1:-}"
      if [[ "${MOCK_REPO_CREATE_EXIT:-0}" -ne 0 ]]; then
        exit "${MOCK_REPO_CREATE_EXIT}"
      fi
      if [[ -n "${GIT_FIXTURE_ROOT:-}" && -n "$spec" ]]; then
        bare="${GIT_FIXTURE_ROOT}/remotes/${spec}.git"
        mkdir -p "$(dirname "$bare")"
        git init --bare "$bare" >/dev/null 2>&1
      fi
      exit 0
    fi
    ;;
  api)
    if [[ "${1:-}" == "--method" && "${2:-}" == "PATCH" ]]; then
      if [[ -n "${MOCK_GH_PATCH_LOG:-}" ]]; then
        printf '%s\n' "$*" >> "$MOCK_GH_PATCH_LOG"
      fi
      exit "${MOCK_GH_PATCH_EXIT:-0}"
    fi
    api_url="${*}"
    if [[ "$api_url" == *libraries.json* ]]; then
      if [[ -n "${MOCK_LIBRARIES_FIXTURE:-}" && -f "$MOCK_LIBRARIES_FIXTURE" ]]; then
        cat "$MOCK_LIBRARIES_FIXTURE"
      fi
      exit "${MOCK_GH_API_EXIT:-0}"
    fi
    exit "${MOCK_GH_API_EXIT:-1}"
    ;;
  pr)
    if [[ "${1:-}" == "list" ]]; then
      if [[ -n "${MOCK_PR_LIST_STDERR:-}" ]]; then
        printf '%s\n' "$MOCK_PR_LIST_STDERR" >&2
      fi
      if [[ -n "${MOCK_PR_LIST_STDOUT:-}" ]]; then
        printf '%s\n' "$MOCK_PR_LIST_STDOUT"
      fi
      exit "${MOCK_PR_LIST_EXIT:-0}"
    fi
    ;;
  run)
    if [[ "${1:-}" == "view" ]]; then
      if [[ "${MOCK_RUN_VIEW_EXIT:-0}" -ne 0 ]]; then
        exit "${MOCK_RUN_VIEW_EXIT}"
      fi
      if [[ -n "${MOCK_RUN_VIEW_JSON:-}" ]]; then
        printf '%s\n' "$MOCK_RUN_VIEW_JSON"
      else
        printf '%s\n' '{"jobs":[]}'
      fi
      exit 0
    fi
    if [[ "${1:-}" == "list" ]]; then
      limit=20
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --limit)
            limit="${2:-20}"
            shift 2
            ;;
          *)
            shift
            ;;
        esac
      done
      if [[ -n "${MOCK_RUN_LIST_JSON:-}" ]]; then
        jq --argjson n "$limit" '.[0:$n]' <<<"$MOCK_RUN_LIST_JSON"
      else
        printf '%s\n' '[]'
      fi
      exit "${MOCK_RUN_LIST_EXIT:-0}"
    fi
    ;;
esac

echo "mock gh: unhandled invocation: gh $*" >&2
exit 127
MOCK_EOF
  chmod +x "$MOCK_GH_DIR/gh"
  export PATH="$MOCK_GH_DIR:$PATH"
}

restore_mock_gh() {
  if [[ -n "$_ORIG_PATH" ]]; then
    export PATH="$_ORIG_PATH"
  fi
  if [[ -n "$MOCK_GH_DIR" && -d "$MOCK_GH_DIR" ]]; then
    rm -rf "$MOCK_GH_DIR"
  fi
  unset MOCK_GH_DIR _ORIG_PATH
  unset MOCK_REPO_VIEW_EXIT MOCK_LIBRARIES_FIXTURE MOCK_GH_API_EXIT
  unset MOCK_REPO_CREATE_EXIT MOCK_GH_PATCH_LOG MOCK_GH_PATCH_EXIT
  unset MOCK_PR_LIST_STDOUT MOCK_PR_LIST_STDERR MOCK_PR_LIST_EXIT
  unset MOCK_RUN_VIEW_EXIT MOCK_RUN_VIEW_JSON
  unset MOCK_RUN_LIST_JSON MOCK_RUN_LIST_EXIT
}

reset_mock_gh() {
  export MOCK_REPO_VIEW_EXIT=0
  export MOCK_GH_PATCH_EXIT=0
  export MOCK_RUN_VIEW_EXIT=0
  unset MOCK_LIBRARIES_FIXTURE MOCK_GH_API_EXIT MOCK_REPO_CREATE_EXIT
  unset MOCK_PR_LIST_STDOUT MOCK_PR_LIST_STDERR MOCK_PR_LIST_EXIT
  unset MOCK_RUN_VIEW_JSON MOCK_RUN_LIST_JSON
  export MOCK_PR_LIST_EXIT=0
  export MOCK_RUN_LIST_EXIT=0
  if [[ -n "${MOCK_GH_DIR:-}" ]]; then
    MOCK_GH_PATCH_LOG="$MOCK_GH_DIR/gh-patch.log"
    : > "$MOCK_GH_PATCH_LOG"
    export MOCK_GH_PATCH_LOG
  fi
}
