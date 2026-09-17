# shellcheck shell=bash
# Shared shell library for add-submodules and start-translation workflows.
# Source env.sh before lib.sh so ORG, MODULE_ORG, BOT_NAME, BOT_EMAIL, BOOST_ORG, MASTER_BRANCH,
# LOCAL_BRANCH_PREFIX, TRANSLATION_BRANCH_PREFIX, WEBLATE_ENDPOINT_PATH, and TRANSLATIONS_REPO
# are set. Workflows also set GITHUB_TOKEN (from secrets.SYNC_TOKEN — broad PAT),
# LANG_CODES, and (for start-translation) WEBLATE_URL / WEBLATE_TOKEN in the step
# env before sourcing. Some workflows set GH_TOKEN to the ephemeral Actions token
# (e.g. heartbeat.yml for gh CLI); that is not the same privilege level as GITHUB_TOKEN.
# Call validate_secrets (or validate_secrets weblate) after sourcing env.sh and lib.sh.
#
# Per-submodule batch return convention (see docs/ARCHITECTURE.md §6):
#   0 = success, 1 = non-fatal skip, 2 = fatal error.
# Exception: has_open_translation_pr uses a separate tri-state (0=PR exists, 1=none, 2=API fail).

# ── Helpers ──────────────────────────────────────────────────────────

CURRENT_PHASE=""

begin_phase() {
  CURRENT_PHASE="$1"
  echo "::group::[$1] ${2:-}"
}

end_phase() {
  echo "::endgroup::"
  CURRENT_PHASE=""
}

phase_err() {
  echo "Error: [${CURRENT_PHASE:-unknown}] $*" >&2
}

is_valid_event_type() {
  local et="$1" v
  for v in "${VALID_EVENT_TYPES[@]}"; do
    [[ "$et" == "$v" ]] && return 0
  done
  return 1
}

validate_event_type() {
  is_valid_event_type "$1" || {
    phase_err "invalid event_type='$1'; expected one of: ${VALID_EVENT_TYPES[*]}"
    exit 1
  }
}

set_git_bot_config() {
  git -C "$1" config user.email "$BOT_EMAIL"
  git -C "$1" config user.name "$BOT_NAME"
}

# ── GitHub API helpers (via gh CLI) ──────────────────────────────────

repo_exists() { gh repo view "$1/$2" &>/dev/null; }

# Returns 0 if org/repo has an open PR into local-{lang_code} with head matching
# "translation-{lang_code}-*"; 1 if none; 2 if the GitHub API check failed.
has_open_translation_pr() {
  local org="$1" repo="$2" lang_code="$3"
  local base_br="${LOCAL_BRANCH_PREFIX}${lang_code}"
  local output
  if ! output=$(gh pr list --repo "$org/$repo" --state open --base "$base_br" --json headRefName \
    --jq ".[] | select(.headRefName | startswith(\"${TRANSLATION_BRANCH_PREFIX}${lang_code}-\")) | .headRefName" \
    2>&1); then
    echo "  Error: could not list open PRs for $org/$repo (base=$base_br): $output" >&2
    return 2
  fi
  [[ -n "$output" ]]
}

# ── Git clone helpers ────────────────────────────────────────────────

# Clone repo at branch/tag into $3. Pass "keep" as $4 to preserve .git.
clone_repo() {
  mkdir -p "$3"
  git clone --branch "$2" "$1" "$3" || return 2
  [[ "${4:-}" == "keep" ]] || rm -rf "$3/.git"
}

# ── Doc-path helpers ─────────────────────────────────────────────────

# Fetch meta/libraries.json via gh API; emit one doc-path per line.
get_doc_paths() {
  local repo="$1" ref="$2" json
  json=$(gh api "repos/${BOOST_ORG}/${repo}/contents/meta/libraries.json?ref=${ref}" \
    -H "Accept: application/vnd.github.v3.raw" 2>/dev/null) || return 1
  echo "$json" | jq -r --arg repo "$repo" '
    (if type == "array" then . else [.] end)
    | .[]
    | select(type == "object")
    | select((.name // "") != "" and (.key // "") != "")
    | .key as $key
    | if $key == $repo then "doc"
      elif ($key | startswith($repo + "/")) then ($key[($repo | length + 1):] + "/doc")
      else ($key + "/doc")
      end
  '
}

# Prune a cloned repo to only root files + the given doc-path subtrees.
# E.g. ("doc") → keep all root files + entire doc/.
#      ("minmax/doc" "string/doc") → keep root files + those two subtrees.
prune_to_doc_only() {
  local dir="$1"; shift
  local keep_paths=("$@")
  [[ ${#keep_paths[@]} -eq 0 ]] && return

  local first_segs=()
  for p in "${keep_paths[@]}"; do first_segs+=("${p%%/*}"); done

  # Delete root-level dirs not needed by any keep path.
  # Use find instead of glob so dotdirs (e.g. .drone, .github) are included.
  while IFS= read -r item; do
    local name="${item##*/}"
    local needed=0
    for seg in "${first_segs[@]}"; do
      [[ "$name" == "$seg" ]] && { needed=1; break; }
    done
    [[ $needed -eq 0 ]] && rm -rf "$item"
  done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)

  # For paths deeper than one level (e.g. "minmax/doc"), prune the
  # intermediate directory so only the target subdir survives.
  for p in "${keep_paths[@]}"; do
    local first="${p%%/*}"
    [[ "$first" == "$p" ]] && continue  # depth 1 ("doc"): keep entire dir
    local rest_first="${p#"${first}"/}"; rest_first="${rest_first%%/*}"
    for f in "$dir/$first"/*; do [[ -f "$f" ]] && rm -f "$f"; done
    while IFS= read -r item; do
      local name="${item##*/}"
      [[ "$name" == "$rest_first" ]] || rm -rf "$item"
    done < <(find "$dir/$first" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  done
}

# ── Organization repo helpers ────────────────────────────────────────

# Copy create-tag.yml asset into repo.
add_create_tag_workflow() {
  local repo_dir="$1" wf_dir="$1/.github/workflows"
  mkdir -p "$wf_dir/assets"
  cp "$GITHUB_WORKSPACE/.github/workflows/assets/create-tag.yml" \
    "$wf_dir/create-tag.yml"
  cp "$GITHUB_WORKSPACE/.github/workflows/assets/env.sh" \
    "$wf_dir/assets/env.sh"
  set_git_bot_config "$repo_dir"
  git -C "$repo_dir" add ".github/workflows/create-tag.yml" ".github/workflows/assets/env.sh"
  git -C "$repo_dir" commit -m "Add create-tag workflow"
}

# ── Translations repo helpers ─────────────────────────────────────────

ensure_local_branch_in_translations() {
  local dir="$1" lang_code="$2"
  local branch="${LOCAL_BRANCH_PREFIX}${lang_code}"
  if git -C "$dir" ls-remote --exit-code --heads origin "$branch" &>/dev/null; then
    echo "  Branch $branch already exists in $TRANSLATIONS_REPO." >&2
    return 0
  fi
  echo "  Creating branch $branch in $TRANSLATIONS_REPO from $MASTER_BRANCH..." >&2
  git -C "$dir" checkout -B "$MASTER_BRANCH" "origin/$MASTER_BRANCH" || return 1
  git -C "$dir" checkout -b "$branch" || return 1
  rm -rf "$dir/libs" "$dir/.gitmodules"
  git -C "$dir" rm -rf --cached libs .gitmodules 2>/dev/null || true
  if ! git -C "$dir" diff --cached --quiet; then
    git -C "$dir" commit -m "Init $branch" || return 1
  fi
  git -C "$dir" push -u origin "$branch" || return 1
  echo "  Created branch $branch." >&2
  return 0
}

ensure_translations_cloned() {
  [[ -d "$3/.git" ]] && return
  clone_repo "https://github.com/${1}/${2}.git" "$MASTER_BRANCH" "$3" keep
  set_git_bot_config "$3"
}

submodule_in_gitmodules() {
  git -C "$1" config --file .gitmodules --get "submodule.${2}.url" &>/dev/null
}

update_translations_submodule() {
  local dir="$1" org="$2" sub_name="$3" branch="$4"
  local libs_path="$dir/libs/$sub_name"
  local sub_path="libs/$sub_name"
  local sub_url="https://github.com/${org}/${sub_name}.git"

  if submodule_in_gitmodules "$dir" "$sub_path" && [[ -d "$libs_path" ]]; then
    if ! git -C "$dir" submodule update --init "$sub_path"; then
      echo "  submodule update --init failed for $sub_path" >&2
      return 1
    fi
    git -C "$dir" config "submodule.${sub_path}.branch" "$branch"
    if ! git -C "$dir" submodule update --remote "$sub_path"; then
      echo "  submodule update --remote failed for $sub_path" >&2; return 1
    fi
    git -C "$dir" add "$sub_path"
  else
    # Submodule not registered on this branch yet; add it fresh.
    rm -rf "$libs_path" "$dir/.git/modules/$sub_path"
    git -C "$dir" submodule add -b "$branch" "$sub_url" "$sub_path"
    git -C "$dir" add .gitmodules "$sub_path"
  fi
}

# `git push -h` exits 129, so capture the help text first (|| true) and grep it
# separately. Piping straight into grep would fail the probe under `set -o
# pipefail` (which the workflows enable) even when the flag is present.
git_push_help_mentions() {
  local help
  help="$(git push -h 2>&1 || true)"
  grep -qF "$1" <<<"$help"
}

git_push_supports_force_with_lease() {
  git_push_help_mentions 'force-with-lease'
}

# --force-if-includes (Git 2.30+) makes the safe retry below reject an unmerged
# remote advance instead of overwriting it.
git_push_supports_force_if_includes() {
  git_push_help_mentions 'force-if-includes'
}

commit_and_push_translations_branch() {
  local dir="$1" branch="$2" libs_ref="$3" force="${4:-false}"
  local push_rc remote_sha fetch_rc attempt max_attempts=3
  git -C "$dir" status --short
  if git -C "$dir" diff --cached --quiet; then
    echo "  No staged submodule changes on $branch; skipping commit." >&2
  else
    git -C "$dir" commit -m "Update libs submodules to $libs_ref"
  fi
  if [[ "$force" == "true" ]]; then
    if ! git_push_supports_force_with_lease; then
      phase_err "git push --force-with-lease is not supported by this Git installation"
      return 1
    fi
    if ! git_push_supports_force_if_includes; then
      phase_err "git push --force-if-includes is not supported; requires Git 2.30+"
      return 1
    fi
    # A concurrent advance rejects the lease. Fetch so the lease reflects the
    # advanced remote and retry, but keep --force-if-includes so the retry still
    # rejects an advance we never integrated. A spurious rejection (remote
    # unchanged from our base) retries to success; a real concurrent commit
    # fails closed rather than being silently overwritten.
    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
      if git -C "$dir" push --force-with-lease --force-if-includes origin "$branch"; then
        return 0
      else
        push_rc=$?
      fi
      if (( attempt < max_attempts )); then
        # A failed fetch (auth/network) leaves the tracking ref stale, so a
        # retry can't satisfy the lease. Fail with the real cause instead of
        # letting the loop misreport it as a concurrent-advance rejection.
        git -C "$dir" fetch origin "$branch" || {
          fetch_rc=$?
          phase_err "failed to fetch origin/$branch before retrying the push"
          return "$fetch_rc"
        }
      fi
    done
    remote_sha=$(git -C "$dir" ls-remote --heads origin "$branch" | awk '{print $1}')
    phase_err "force-with-lease push rejected for branch $branch (remote HEAD=${remote_sha:-unknown}); remote may have advanced concurrently — re-run after fetch or resolve manually."
    return "$push_rc"
  else
    git -C "$dir" push origin "$branch"
  fi
}

# Update one branch of the translations super-repo (checkout → update pointers → push).
sync_translations_branch() {
  local dir="$1" branch="$2" libs_ref="$3" force="${4:-false}"
  local sub
  git -C "$dir" checkout -B "$branch" "origin/$branch"
  for sub in "${UPDATES[@]}"; do
    update_translations_submodule "$dir" "$MODULE_ORG" "$sub" "$branch" || return 2
  done
  commit_and_push_translations_branch "$dir" "$branch" "$libs_ref" "$force"
}

finalize_translations_master() {
  local dir="$1" libs_ref="$2"
  [[ ${#UPDATES[@]} -eq 0 ]] && return
  git -C "$dir" fetch origin
  sync_translations_branch "$dir" "$MASTER_BRANCH" "$libs_ref"
}

finalize_translations_local() {
  local dir="$1" libs_ref="$2" lang_code="$3"
  [[ ${#UPDATES[@]} -eq 0 ]] && return
  git -C "$dir" fetch origin
  sync_translations_branch "$dir" "${LOCAL_BRANCH_PREFIX}${lang_code}" "$libs_ref" true
}

# Used by add-submodules.yml (start-translation calls finalize_translations_* directly).
finalize_translations_repo() {
  local dir="$1" libs_ref="$2"
  shift 2
  local lang_codes_arr=("$@") lang_code

  finalize_translations_master "$dir" "$libs_ref" || return $?
  for lang_code in "${lang_codes_arr[@]}"; do
    finalize_translations_local "$dir" "$libs_ref" "$lang_code" || return $?
  done
}

# ── Translation workflow state ─────────────────────────────────────────
#
# Mutable globals accumulated during per-submodule processing:
#
#   UPDATES (indexed array)
#     Ordered, deduplicated list of successfully processed submodule names
#     (basename only, e.g. "algorithm", not "libs/algorithm").
#     Written via record_submodule_update; consumed by finalize_translations_*.
#
#   add_or_update (associative array: lang_code → space-separated names)
#     Submodule names eligible for Weblate per language; only submodules that
#     passed process_local_branch. Written via record_add_or_update_submodule;
#     consumed by trigger_weblate (translation.sh).
#
#   SUBMODULE_FATAL (indexed array)
#     Submodule names that returned fatal (return 2) from add_one_submodule or
#     sync_one_submodule. See docs/ARCHITECTURE.md §6.
#
#   OPEN_PR_SKIP (indexed array)
#     Submodule names skipped due to an open translation PR (start-translation local).

init_translation_state() {
  UPDATES=()
  SUBMODULE_FATAL=()
  OPEN_PR_SKIP=()
  declare -gA add_or_update=()
}

init_add_or_update_lang() {
  local lang_code="$1"
  is_valid_lang_code "$lang_code" || {
    phase_err "invalid language code: '$lang_code'"
    return 1
  }
  add_or_update["$lang_code"]=""
}

# Return 0 when $1 is a well-formed Boost libs/ submodule basename.
is_valid_submodule_name() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  # Basename only (e.g. algorithm, multi_index). No slashes or whitespace.
  [[ "$name" =~ ^[a-z][a-z0-9._-]*$ ]]
}

_submodule_in_updates() {
  local sub_name="$1" sub
  for sub in "${UPDATES[@]}"; do
    [[ "$sub" == "$sub_name" ]] && return 0
  done
  return 1
}

_submodule_in_add_or_update() {
  local lang_code="$1" sub_name="$2" subs sub
  subs="${add_or_update[$lang_code]:-}"
  [[ -z "$subs" ]] && return 1
  for sub in $subs; do
    [[ "$sub" == "$sub_name" ]] && return 0
  done
  return 1
}

_submodule_in_array() {
  local name="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$name" ]] && return 0
  done
  return 1
}

# Append a fatal submodule name (idempotent on duplicate).
record_submodule_fatal() {
  local sub_name="$1"
  _submodule_in_array "$sub_name" "${SUBMODULE_FATAL[@]}" && return 0
  SUBMODULE_FATAL+=("$sub_name")
}

# Summary bucket globals; filled by sync_one_submodule before print_submodule_processing_summary.
init_submodule_summary_buckets() {
  META_MISSING=()
  NO_DOC_PATHS=()
  ORG_REPO_MISSING=()
  REPO_EXISTS_SKIP=()
}

# Print consolidated success / failure / skip summary after the per-submodule loop.
print_submodule_processing_summary() {
  local -a processing_errors=() repo_exists_skip=()
  local -a meta_missing=() org_repo_missing=() no_doc_paths=()
  local sub

  [[ ${META_MISSING+set} ]] && meta_missing=("${META_MISSING[@]}")
  [[ ${ORG_REPO_MISSING+set} ]] && org_repo_missing=("${ORG_REPO_MISSING[@]}")
  [[ ${NO_DOC_PATHS+set} ]] && no_doc_paths=("${NO_DOC_PATHS[@]}")
  [[ ${REPO_EXISTS_SKIP+set} ]] && repo_exists_skip=("${REPO_EXISTS_SKIP[@]}")

  for sub in "${SUBMODULE_FATAL[@]}"; do
    _submodule_in_array "$sub" "${meta_missing[@]}" && continue
    _submodule_in_array "$sub" "${org_repo_missing[@]}" && continue
    processing_errors+=("$sub")
  done

  echo "── Submodule processing summary ──" >&2
  echo "  Successfully updated (${#UPDATES[@]}): $([[ ${#UPDATES[@]} -eq 0 ]] && echo '(none)' || echo "${UPDATES[*]}")" >&2
  echo "  Failed — Type 1, missing meta/libraries.json (${#meta_missing[@]}): $([[ ${#meta_missing[@]} -eq 0 ]] && echo '(none)' || echo "${meta_missing[*]}")" >&2
  echo "  Failed — Type 3, org repo missing (${#org_repo_missing[@]}): $([[ ${#org_repo_missing[@]} -eq 0 ]] && echo '(none)' || echo "${org_repo_missing[*]}")" >&2
  echo "  Failed — processing error (${#processing_errors[@]}): $([[ ${#processing_errors[@]} -eq 0 ]] && echo '(none)' || echo "${processing_errors[*]}")" >&2
  echo "  Skipped — Type 2, no doc paths (${#no_doc_paths[@]}): $([[ ${#no_doc_paths[@]} -eq 0 ]] && echo '(none)' || echo "${no_doc_paths[*]}")" >&2
  echo "  Skipped — org repo already exists (${#repo_exists_skip[@]}): $([[ ${#repo_exists_skip[@]} -eq 0 ]] && echo '(none)' || echo "${repo_exists_skip[*]}")" >&2
  echo "  Skipped — open translation PR (${#OPEN_PR_SKIP[@]}): $([[ ${#OPEN_PR_SKIP[@]} -eq 0 ]] && echo '(none)' || echo "${OPEN_PR_SKIP[*]}")" >&2
}

# Append a successfully processed submodule to UPDATES (idempotent on duplicate).
record_submodule_update() {
  local sub_name="$1"
  is_valid_submodule_name "$sub_name" || {
    phase_err "invalid submodule name: '$sub_name'"
    return 1
  }
  _submodule_in_updates "$sub_name" && return 0
  UPDATES+=("$sub_name")
}

# Append a Weblate-eligible submodule for lang_code (idempotent on duplicate).
record_add_or_update_submodule() {
  local lang_code="$1" sub_name="$2"
  is_valid_lang_code "$lang_code" || {
    phase_err "invalid language code: '$lang_code'"
    return 1
  }
  is_valid_submodule_name "$sub_name" || {
    phase_err "invalid submodule name: '$sub_name'"
    return 1
  }
  _submodule_in_add_or_update "$lang_code" "$sub_name" && return 0
  if [[ -n "${add_or_update[$lang_code]:-}" ]]; then
    add_or_update["$lang_code"]+=" $sub_name"
  else
    add_or_update["$lang_code"]="$sub_name"
  fi
}

# Validate a space-separated add_or_update value before Weblate POST.
validate_add_or_update_entry() {
  local lang_code="$1" subs="$2"
  [[ -n "$subs" ]] || {
    phase_err "add_or_update[$lang_code] is empty"
    return 1
  }
  local sub
  for sub in $subs; do
    is_valid_submodule_name "$sub" || {
      phase_err "invalid submodule name in add_or_update[$lang_code]: '$sub'"
      return 1
    }
  done
}

# ── Parsing helpers ───────────────────────────────────────────────────

# Emit a compact JSON array of submodule basenames (empty → []).
submodule_names_to_json() {
  if [[ $# -eq 0 ]]; then
    echo '[]'
    return
  fi
  printf '%s\n' "$@" | jq -R . | jq -s -c .
}

# Parse JSON array of submodule basenames; one name per line (empty/no-op for []).
parse_submodule_names_json() {
  local json="${1:-}"
  [[ -z "$json" || "$json" == "[]" ]] && return 0
  jq -r '.[]' <<< "$json"
}

# Parse "[zh_Hans, en]" or "zh_Hans,en" into one code per line.
parse_list() {
  local s="$1"
  s="${s//[[:space:]]/}"
  s="${s#[}"; s="${s%]}"
  [[ -z "$s" ]] && return
  IFS=',' read -ra parts <<< "$s"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] && echo "$part"
  done
}

# Parse "[.adoc, .md]" or '[".adoc",".md"]' into one extension per line.
parse_extensions() {
  local s="$1"
  s="${s//[[:space:]]/}"; [[ -z "$s" ]] && return
  s="${s#[}"; s="${s%]}"
  local result=()
  IFS=',' read -ra parts <<< "$s"
  for part in "${parts[@]}"; do
    part="${part//\"/}"; part="${part//\'/}"
    [[ -z "$part" ]] && continue
    [[ "$part" == .* ]] || part=".${part}"
    result+=("$part")
  done
  printf '%s\n' "${result[@]}"
}

# Return 0 when $1 is a well-formed Weblate language code.
is_valid_lang_code() {
  local code="$1"
  [[ -n "$code" ]] || return 1
  # ISO 639-1/2/3 primary (2–3 letters) + optional BCP 47 subtags (_ or -).
  # Rejects spaces, slashes, and other git-ref-hostile characters.
  [[ "$code" =~ ^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$ ]]
}

# Exit 1 with a clear message if any argument is invalid.
validate_lang_codes() {
  local invalid=() code
  for code in "$@"; do
    is_valid_lang_code "$code" || invalid+=("$code")
  done
  if [[ ${#invalid[@]} -gt 0 ]]; then
    echo "Error: invalid language code(s): ${invalid[*]}" >&2
    echo "Expected ISO 639-1/2/3 or BCP 47 (e.g. en, zh_Hans, pt_BR)." >&2
    exit 1
  fi
}

# Exit 1 if LANG_CODES workflow env is unset or empty.
require_lang_codes() {
  [[ -n "${LANG_CODES:-}" ]] || {
    phase_err "lang_codes not set in client_payload or vars.LANG_CODES."
    end_phase
    exit 1
  }
}

# Read LANG_CODES env, populate global lang_codes_arr, exit 1 on missing/empty/invalid.
parse_and_validate_lang_codes() {
  require_lang_codes
  mapfile -t lang_codes_arr < <(parse_list "$LANG_CODES")
  [[ ${#lang_codes_arr[@]} -eq 0 ]] && {
    phase_err "LANG_CODES parsed to empty list."
    end_phase
    exit 1
  }
  validate_lang_codes "${lang_codes_arr[@]}"
}

# Exit 1 if a named variable is unset or empty.
_require_nonempty() {
  local var_name="$1" msg="$2"
  # :- keeps indirect expansion safe under set -u when the named var is unset.
  [[ -n "${!var_name:-}" ]] || {
    phase_err "$msg"
    end_phase
    exit 1
  }
}

# validate_secrets [weblate]
# Call after: source env.sh && source lib.sh
# Reads workflow env + env.sh globals; exits 1 with a clear message on first failure.
# Lang validation runs only when LANG_CODE or LANG_CODES is set (e.g. skipped by sync-mirrors).
validate_secrets() {
  local require_weblate=0
  [[ "${1:-}" == "weblate" ]] && require_weblate=1

  _require_nonempty GITHUB_TOKEN "SYNC_TOKEN secret is not set (mapped to GITHUB_TOKEN in workflow env)."
  if [[ -n "${LANG_CODE:-}" ]]; then
    validate_lang_codes "$LANG_CODE"
  elif [[ -n "${LANG_CODES:-}" ]]; then
    require_lang_codes
  fi
  _require_nonempty ORG "ORG is not set."
  _require_nonempty MODULE_ORG "MODULE_ORG is not set."
  _require_nonempty BOT_NAME "BOT_NAME is not set."
  _require_nonempty BOT_EMAIL "BOT_EMAIL is not set."
  _require_nonempty BOOST_ORG "BOOST_ORG is not set."
  _require_nonempty MASTER_BRANCH "MASTER_BRANCH is not set."
  _require_nonempty TRANSLATIONS_REPO "TRANSLATIONS_REPO is not set."

  if [[ "$require_weblate" -eq 1 ]]; then
    _require_nonempty WEBLATE_URL "WEBLATE_URL secret is not set."
    _require_nonempty WEBLATE_TOKEN "WEBLATE_TOKEN secret is not set."
  fi
}

# True (exit 0) when the last successful scheduled sync is missing or older than
# max_age_seconds, i.e. the daily run has silently stopped. Pure function; the
# heartbeat workflow supplies the timestamps from the GitHub API.
heartbeat_run_is_stale() {
  local last_success_epoch="$1" now_epoch="$2" max_age_seconds="$3"
  [[ -z "$last_success_epoch" || "$last_success_epoch" == "0" ]] && return 0
  (( now_epoch - last_success_epoch > max_age_seconds ))
}

# Read a gh run list JSON array from stdin ({createdAt,event,conclusion} per
# row). Emit the newest createdAt among successful scheduled runs. Empty or
# no-match input emits nothing so the heartbeat treats it as none on record.
# Callers must not pass --event/--status/--branch/--created to gh: those
# filters use GitHub's search index, whose first page is not reliably newest.
latest_successful_scheduled_created_at() {
  jq -r '
    [ .[]
      | select(.event == "schedule" and .conclusion == "success")
      | .createdAt
    ]
    | sort
    | .[-1] // empty
  '
}
