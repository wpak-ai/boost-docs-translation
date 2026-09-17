# shellcheck shell=bash
# shellcheck disable=SC2034
# Variables in this file are consumed by lib.sh and workflow run blocks after `source`.

# Common variables for all workflows. Source this file before lib.sh.

if [[ -z "${_ENV_SH_LOADED:-}" ]]; then
  _ENV_SH_LOADED=1

  # Pipeline phases (used in ::group:: headers and error messages).
  readonly PHASE_SETUP="setup"
  readonly PHASE_ENSURE_BRANCHES="ensure-branches"
  readonly PHASE_PROCESS_SUBMODULES="process-submodules"
  readonly PHASE_FINALIZE_TRANSLATIONS="finalize-translations"
  readonly PHASE_TRIGGER_WEBLATE="trigger-weblate"
  readonly PHASE_DISCOVER="discover"
  readonly PHASE_SYNC_POINTERS="sync-pointers"
  readonly PHASE_HEARTBEAT="heartbeat"

  # Missed-run heartbeat: alert when the last successful scheduled sync is older
  # than this. Margin above the 24h cron cadence so a delayed run does not trip the alert.
  readonly HEARTBEAT_MAX_AGE_HOURS=30
  # Unfiltered gh run list page size / ceiling while covering HEARTBEAT_MAX_AGE_HOURS.
  # Search filters (--event/--status/--created/--branch) are not used; see lib.sh.
  readonly HEARTBEAT_RUN_LIST_PAGE_SIZE=100
  readonly HEARTBEAT_RUN_LIST_MAX=1000

  # start-translation submodule mode (START_PHASE env).
  readonly START_PHASE_MIRRORS="mirrors"
  readonly START_PHASE_LOCAL="local"

  # repository_dispatch event types (must match workflow on.repository_dispatch.types).
  readonly EVENT_ADD_SUBMODULES="add-submodules"
  readonly EVENT_START_TRANSLATION="start-translation"
  readonly EVENT_SYNC_TRANSLATION="sync-translation"
  readonly -a VALID_EVENT_TYPES=(
    "$EVENT_ADD_SUBMODULES"
    "$EVENT_START_TRANSLATION"
    "$EVENT_SYNC_TRANSLATION"
  )
fi

_repo="${GITHUB_REPOSITORY:-}"
ORG="${_repo%%/*}"
TRANSLATIONS_REPO="${_repo##*/}"
unset _repo

BOT_NAME="Boost-Translation-CI-Bot"
BOT_EMAIL="Boost-Translation-CI-Bot@$ORG.local"

BOOST_ORG="boostorg"
MASTER_BRANCH="master"
LOCAL_BRANCH_PREFIX="local-"
TRANSLATION_BRANCH_PREFIX="translation-"
WEBLATE_ENDPOINT_PATH="boost-endpoint/add-or-update/"

# Per-library GitHub org (e.g. CppDigest for https://github.com/CppDigest/<lib>).
# Pass SUBMODULES_ORG in workflow env (repository variable) to use a different org; otherwise
# it defaults to ORG.
if [[ -n "${SUBMODULES_ORG:-}" ]]; then
  MODULE_ORG="$SUBMODULES_ORG"
else
  MODULE_ORG="$ORG"
fi
