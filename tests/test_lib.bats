#!/usr/bin/env bats

setup() {
  # shellcheck source=tests/helpers/common.bash
  source "$BATS_TEST_DIRNAME/helpers/common.bash"
  load_lib
}

teardown() {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  restore_git_push_pre_hook
  cleanup_git_fixture_root
}

@test "parse_list: empty input produces no output" {
  run parse_list ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "parse_list: comma-separated codes" {
  run parse_list "zh_Hans,en"
  [ "$status" -eq 0 ]
  [ "$output" = $'zh_Hans\nen' ]
}

@test "parse_list: bracketed list with spaces" {
  run parse_list "[zh_Hans, en]"
  [ "$status" -eq 0 ]
  [ "$output" = $'zh_Hans\nen' ]
}

@test "parse_list: trailing comma ignored" {
  run parse_list "en,"
  [ "$status" -eq 0 ]
  [ "$output" = "en" ]
}

@test "submodule_names_to_json: empty array" {
  run submodule_names_to_json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "submodule_names_to_json: encodes names" {
  run submodule_names_to_json algorithm system
  [ "$status" -eq 0 ]
  [ "$output" = '["algorithm","system"]' ]
}

@test "parse_submodule_names_json: empty and populated" {
  run parse_submodule_names_json '[]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run parse_submodule_names_json '["algorithm","system"]'
  [ "$status" -eq 0 ]
  [ "$output" = $'algorithm\nsystem' ]
}

@test "parse_extensions: bracketed extensions" {
  run parse_extensions "[.adoc, .md]"
  [ "$status" -eq 0 ]
  [ "$output" = $'.adoc\n.md' ]
}

@test "parse_extensions: JSON-style quoted extensions" {
  run parse_extensions '[".adoc",".md"]'
  [ "$status" -eq 0 ]
  [ "$output" = $'.adoc\n.md' ]
}

@test "parse_extensions: bare extension gets dot prefix" {
  run parse_extensions "adoc"
  [ "$status" -eq 0 ]
  [ "$output" = ".adoc" ]
}

@test "parse_extensions: empty input produces no output" {
  run parse_extensions ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "is_valid_lang_code: accepts common BCP 47 codes" {
  is_valid_lang_code "en"
  is_valid_lang_code "zh_Hans"
  is_valid_lang_code "pt_BR"
}

@test "is_valid_lang_code: rejects invalid codes" {
  ! is_valid_lang_code ""
  ! is_valid_lang_code "en US"
  ! is_valid_lang_code "zh/Hans"
  ! is_valid_lang_code "a"
}

@test "parse_and_validate_lang_codes: valid LANG_CODES populates lang_codes_arr" {
  LANG_CODES="zh_Hans,en"
  parse_and_validate_lang_codes
  [ "${#lang_codes_arr[@]}" -eq 2 ]
  [ "${lang_codes_arr[0]}" = "zh_Hans" ]
  [ "${lang_codes_arr[1]}" = "en" ]
}

@test "parse_and_validate_lang_codes: missing LANG_CODES exits 1" {
  unset LANG_CODES
  run parse_and_validate_lang_codes
  [ "$status" -eq 1 ]
  [[ "$output" == *"lang_codes not set"* ]]
}

@test "parse_and_validate_lang_codes: empty LANG_CODES exits 1" {
  LANG_CODES=""
  run parse_and_validate_lang_codes
  [ "$status" -eq 1 ]
  [[ "$output" == *"lang_codes not set"* ]]
}

@test "parse_and_validate_lang_codes: invalid code exits 1" {
  LANG_CODES="en US"
  run parse_and_validate_lang_codes
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid language code"* ]]
}

@test "get_doc_paths: single-library repo emits doc" {
  # shellcheck source=tests/helpers/mock_gh.bash
  source "$BATS_TEST_DIRNAME/helpers/mock_gh.bash"
  install_mock_gh
  export MOCK_LIBRARIES_FIXTURE="$FIXTURES_DIR/libraries-single.json"

  run get_doc_paths "algorithm" "develop"
  [ "$status" -eq 0 ]
  [ "$output" = "doc" ]

  restore_mock_gh
}

@test "get_doc_paths: multi-library repo emits per-key doc paths" {
  # shellcheck source=tests/helpers/mock_gh.bash
  source "$BATS_TEST_DIRNAME/helpers/mock_gh.bash"
  install_mock_gh
  export MOCK_LIBRARIES_FIXTURE="$FIXTURES_DIR/libraries-multi.json"

  run get_doc_paths "container" "develop"
  [ "$status" -eq 0 ]
  [ "$output" = $'minmax/doc\nstring/doc' ]

  restore_mock_gh
}

@test "get_doc_paths: API failure returns non-zero" {
  # shellcheck source=tests/helpers/mock_gh.bash
  source "$BATS_TEST_DIRNAME/helpers/mock_gh.bash"
  install_mock_gh
  export MOCK_GH_API_EXIT=1

  run get_doc_paths "algorithm" "develop"
  [ "$status" -eq 1 ]

  restore_mock_gh
}

@test "prune_to_doc_only: keeps doc and root files, removes other dirs" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  local_dir="$GIT_FIXTURE_ROOT/prune-single"
  create_prune_fixture_dir "$local_dir"
  echo "root" >"$local_dir/LICENSE"

  prune_to_doc_only "$local_dir" "doc"

  [ -d "$local_dir/doc" ]
  [ -f "$local_dir/LICENSE" ]
  [ ! -d "$local_dir/src" ]
  [ ! -d "$local_dir/.github" ]

  cleanup_git_fixture_root
}

@test "prune_to_doc_only: multi-level path prunes intermediate dirs" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  local_dir="$GIT_FIXTURE_ROOT/prune-multi"
  create_prune_fixture_dir "$local_dir"

  prune_to_doc_only "$local_dir" "minmax/doc"

  [ -d "$local_dir/minmax" ]
  [ ! -d "$local_dir/minmax/other" ]
  [ ! -d "$local_dir/doc" ]
  [ ! -d "$local_dir/src" ]

  cleanup_git_fixture_root
}

@test "clone_repo: failed git clone yields status 2" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  dest="$GIT_FIXTURE_ROOT/clone-dest"

  set +e
  clone_repo "file://$GIT_FIXTURE_ROOT/does-not-exist.git" "master" "$dest" keep
  status=$?
  set -e

  [ "$status" -eq 2 ]
}

@test "finalize_translations_master: no-op when UPDATES empty" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  create_bare_remote_with_clone "translations"
  trans_dir="$GIT_FIXTURE_ROOT/translations-work"
  git clone "$BARE_REMOTE" "$trans_dir"

  UPDATES=()
  SYNC_CALLS=()
  sync_translations_branch() { SYNC_CALLS+=("branch=$2 force=${4:-false}"); }

  finalize_translations_master "$trans_dir" "develop"
  [ "${#SYNC_CALLS[@]}" -eq 0 ]

  cleanup_git_fixture_root
}

@test "finalize_translations_master: syncs master without force" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  create_bare_remote_with_clone "translations"
  trans_dir="$GIT_FIXTURE_ROOT/translations-work"
  git clone "$BARE_REMOTE" "$trans_dir"

  UPDATES=("algorithm")
  SYNC_CALLS=()
  sync_translations_branch() { SYNC_CALLS+=("branch=$2 force=${4:-false}"); }

  finalize_translations_master "$trans_dir" "develop"
  [ "${#SYNC_CALLS[@]}" -eq 1 ]
  [ "${SYNC_CALLS[0]}" = "branch=${MASTER_BRANCH} force=false" ]

  cleanup_git_fixture_root
}

@test "finalize_translations_local: syncs local branch with force" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  create_bare_remote_with_clone "translations"
  trans_dir="$GIT_FIXTURE_ROOT/translations-work"
  git clone "$BARE_REMOTE" "$trans_dir"

  UPDATES=("algorithm")
  SYNC_CALLS=()
  sync_translations_branch() { SYNC_CALLS+=("branch=$2 force=${4:-false}"); }

  finalize_translations_local "$trans_dir" "develop" "en"
  [ "${#SYNC_CALLS[@]}" -eq 1 ]
  [ "${SYNC_CALLS[0]}" = "branch=${LOCAL_BRANCH_PREFIX}en force=true" ]
}

@test "finalize_translations_repo: syncs master then each local branch" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  create_bare_remote_with_clone "translations"
  trans_dir="$GIT_FIXTURE_ROOT/translations-work"
  git clone "$BARE_REMOTE" "$trans_dir"

  UPDATES=("algorithm")
  SYNC_CALLS=()
  sync_translations_branch() { SYNC_CALLS+=("branch=$2 force=${4:-false}"); }

  finalize_translations_repo "$trans_dir" "develop" "en" "zh_Hans"
  [ "${#SYNC_CALLS[@]}" -eq 3 ]
  [ "${SYNC_CALLS[0]}" = "branch=${MASTER_BRANCH} force=false" ]
  [ "${SYNC_CALLS[1]}" = "branch=${LOCAL_BRANCH_PREFIX}en force=true" ]
  [ "${SYNC_CALLS[2]}" = "branch=${LOCAL_BRANCH_PREFIX}zh_Hans force=true" ]

  cleanup_git_fixture_root
}

@test "finalize_translations_repo: stops on first failure" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  create_bare_remote_with_clone "translations"
  trans_dir="$GIT_FIXTURE_ROOT/translations-work"
  git clone "$BARE_REMOTE" "$trans_dir"

  UPDATES=("algorithm")
  SYNC_CALLS=()
  sync_translations_branch() {
    if [[ "$2" == "${MASTER_BRANCH}" ]]; then
      return 1
    fi
    SYNC_CALLS+=("branch=$2 force=${4:-false}")
  }

  if run_fn finalize_translations_repo "$trans_dir" "develop" "en" "zh_Hans"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ]
  [ "${#SYNC_CALLS[@]}" -eq 0 ]

  cleanup_git_fixture_root
}

@test "finalize_translations_local: rejects stale force-with-lease push" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  create_bare_remote_with_clone "translations"
  create_remote_branch "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" "$MASTER_BRANCH"
  trans_dir="$GIT_FIXTURE_ROOT/translations-work"
  git clone "$BARE_REMOTE" "$trans_dir"
  set_git_bot_config "$trans_dir"

  UPDATES=("algorithm")
  update_translations_submodule() { :; }

  install_git_push_pre_hook "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" "concurrent advance"

  local stderr_file="$BATS_TMPDIR/finalize-lease-stderr"
  set +e
  finalize_translations_local "$trans_dir" "develop" "en" 2>"$stderr_file"
  rc=$?
  set -e

  [ "$rc" -ne 0 ]
  remote_sha=$(git ls-remote --heads "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" | awk '{print $1}')
  grep -q "${LOCAL_BRANCH_PREFIX}en" "$stderr_file"
  grep -q "$remote_sha" "$stderr_file"
  grep -q "force-with-lease push rejected" "$stderr_file"
  [ -z "$(git -C "$trans_dir" status --porcelain)" ]
  [ ! -f "$trans_dir/.git/index.lock" ]
  git --git-dir="$BARE_REMOTE" show -s --format=%s "$remote_sha" | grep -q "concurrent advance"
}

@test "finalize_translations_local: does not overwrite a concurrent advance (force-if-includes)" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  create_bare_remote_with_clone "translations"
  create_remote_branch "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" "$MASTER_BRANCH"
  trans_dir="$GIT_FIXTURE_ROOT/translations-work"
  git clone "$BARE_REMOTE" "$trans_dir"
  set_git_bot_config "$trans_dir"

  UPDATES=("algorithm")
  update_translations_submodule() { :; }

  # One concurrent advance: the fetch updates the lease baseline, but
  # --force-if-includes still rejects the retry because that advance was never
  # integrated, so the run fails closed instead of overwriting it.
  install_git_push_pre_hook "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" "concurrent advance" 1

  local stderr_file="$BATS_TMPDIR/finalize-no-overwrite-stderr"
  set +e
  finalize_translations_local "$trans_dir" "develop" "en" 2>"$stderr_file"
  rc=$?
  set -e

  [ "$rc" -ne 0 ]
  grep -q "force-with-lease push rejected" "$stderr_file"
  # the concurrent advance is still the remote tip, not overwritten by our push
  remote_sha=$(git ls-remote --heads "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" | awk '{print $1}')
  git --git-dir="$BARE_REMOTE" show -s --format=%s "$remote_sha" | grep -q "concurrent advance"
}

@test "finalize_translations_local: fails after force-with-lease retries are exhausted" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  create_bare_remote_with_clone "translations"
  create_remote_branch "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" "$MASTER_BRANCH"
  trans_dir="$GIT_FIXTURE_ROOT/translations-work"
  git clone "$BARE_REMOTE" "$trans_dir"
  set_git_bot_config "$trans_dir"

  UPDATES=("algorithm")
  update_translations_submodule() { :; }

  # Advance the remote before every push, so all three attempts are rejected.
  # The counter also records fetches: 1 finalize pre-fetch + 2 between retries.
  local fetch_counter="$BATS_TMPDIR/fetch-count"
  : >"$fetch_counter"
  install_git_fetch_counter "$fetch_counter" "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" "concurrent advance"

  local stderr_file="$BATS_TMPDIR/finalize-exhausted-stderr"
  set +e
  finalize_translations_local "$trans_dir" "develop" "en" 2>"$stderr_file"
  rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$(wc -l <"$fetch_counter")" -eq 3 ]
  grep -q "force-with-lease push rejected" "$stderr_file"
  remote_sha=$(git ls-remote --heads "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" | awk '{print $1}')
  grep -q "$remote_sha" "$stderr_file"
  git --git-dir="$BARE_REMOTE" show -s --format=%s "$remote_sha" | grep -q "concurrent advance"
}

@test "finalize_translations_local: fails with the real cause when an inter-attempt fetch fails" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  create_bare_remote_with_clone "translations"
  create_remote_branch "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" "$MASTER_BRANCH"
  trans_dir="$GIT_FIXTURE_ROOT/translations-work"
  git clone "$BARE_REMOTE" "$trans_dir"
  set_git_bot_config "$trans_dir"

  UPDATES=("algorithm")
  update_translations_submodule() { :; }

  # First push is rejected (one concurrent advance), then the inter-attempt
  # `git fetch origin <branch>` fails.
  install_git_push_pre_hook "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" "concurrent advance" 1 1

  local stderr_file="$BATS_TMPDIR/finalize-fetch-fail-stderr"
  set +e
  finalize_translations_local "$trans_dir" "develop" "en" 2>"$stderr_file"
  rc=$?
  set -e

  [ "$rc" -ne 0 ]
  grep -q "failed to fetch origin/${LOCAL_BRANCH_PREFIX}en" "$stderr_file"
  # not misreported as a concurrent-advance rejection
  ! grep -q "force-with-lease push rejected" "$stderr_file"
}

@test "commit_and_push_translations_branch: clear error when force-with-lease unsupported" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  create_bare_remote_with_clone "translations"
  create_remote_branch "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" "$MASTER_BRANCH"
  trans_dir="$GIT_FIXTURE_ROOT/translations-work"
  git clone "$BARE_REMOTE" "$trans_dir"
  set_git_bot_config "$trans_dir"
  git -C "$trans_dir" checkout "${LOCAL_BRANCH_PREFIX}en"

  install_git_without_force_with_lease

  local stderr_file="$BATS_TMPDIR/push-unsupported-stderr"
  # pipefail is on in the workflows; the probe must still work when `git push -h`
  # exits 129 (the shim mirrors that).
  set +e -o pipefail
  commit_and_push_translations_branch "$trans_dir" "${LOCAL_BRANCH_PREFIX}en" "develop" true \
    2>"$stderr_file"
  rc=$?
  set -e +o pipefail

  [ "$rc" -ne 0 ]
  grep -q "force-with-lease is not supported" "$stderr_file"
  grep -q "not supported by this Git installation" "$stderr_file"
}

@test "commit_and_push_translations_branch: clear error when force-if-includes unsupported" {
  # shellcheck source=tests/helpers/git_fixtures.bash
  source "$BATS_TEST_DIRNAME/helpers/git_fixtures.bash"
  init_git_fixture_root
  create_bare_remote_with_clone "translations"
  create_remote_branch "$BARE_REMOTE" "${LOCAL_BRANCH_PREFIX}en" "$MASTER_BRANCH"
  trans_dir="$GIT_FIXTURE_ROOT/translations-work"
  git clone "$BARE_REMOTE" "$trans_dir"
  set_git_bot_config "$trans_dir"
  git -C "$trans_dir" checkout "${LOCAL_BRANCH_PREFIX}en"

  # force-with-lease present, force-if-includes hidden (pre-2.30 Git).
  install_git_without_force_if_includes

  local stderr_file="$BATS_TMPDIR/push-no-includes-stderr"
  set +e -o pipefail
  commit_and_push_translations_branch "$trans_dir" "${LOCAL_BRANCH_PREFIX}en" "develop" true \
    2>"$stderr_file"
  rc=$?
  set -e +o pipefail

  [ "$rc" -ne 0 ]
  grep -q "force-if-includes is not supported" "$stderr_file"
  grep -q "requires Git 2.30+" "$stderr_file"
}

@test "git_push_supports_* probes are pipefail-safe with real git" {
  # Modern git supports both flags, but `git push -h` exits 129; piped into grep
  # that fails under pipefail even when the flag is present. The probes must
  # still report supported.
  set -o pipefail
  git_push_supports_force_with_lease
  git_push_supports_force_if_includes
  set +o pipefail
}

@test "begin_phase and end_phase: emit group markers and track CURRENT_PHASE" {
  local out_file="$BATS_TMPDIR/phase.out"

  begin_phase "$PHASE_SETUP" "Test setup" >"$out_file"
  [ "$(cat "$out_file")" = "::group::[setup] Test setup" ]
  [ "$CURRENT_PHASE" = "setup" ]

  end_phase >"$out_file"
  [ "$(cat "$out_file")" = "::endgroup::" ]
  [ -z "$CURRENT_PHASE" ]
}

@test "phase_err: includes active phase in message" {
  begin_phase "$PHASE_PROCESS_SUBMODULES" "Process submodules"
  run phase_err "something failed"
  end_phase
  [ "$status" -eq 0 ]
  [[ "$output" == *"[process-submodules] something failed"* ]]
}

@test "phase_err: uses unknown when no phase is active" {
  CURRENT_PHASE=""
  run phase_err "early failure"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[unknown] early failure"* ]]
}

@test "is_valid_event_type: accepts declared event types" {
  is_valid_event_type "$EVENT_ADD_SUBMODULES"
  is_valid_event_type "$EVENT_START_TRANSLATION"
  is_valid_event_type "$EVENT_SYNC_TRANSLATION"
}

@test "is_valid_event_type: rejects unknown event types" {
  ! is_valid_event_type "not-a-real-event"
}

@test "validate_event_type: exits 1 on invalid input" {
  run validate_event_type "bad-event"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid event_type='bad-event'"* ]]
}

@test "validate_secrets weblate: accepts LANG_CODE without LANG_CODES" {
  GITHUB_TOKEN="token"
  LANG_CODE="zh_Hans"
  unset LANG_CODES
  WEBLATE_URL="https://weblate.example"
  WEBLATE_TOKEN="secret"
  validate_secrets weblate
}

@test "is_valid_submodule_name: accepts common Boost lib names" {
  is_valid_submodule_name "algorithm"
  is_valid_submodule_name "multi_index"
}

@test "is_valid_submodule_name: rejects invalid names" {
  ! is_valid_submodule_name ""
  ! is_valid_submodule_name "libs/foo"
  ! is_valid_submodule_name "foo bar"
}

@test "init_add_or_update_lang: rejects invalid language code" {
  init_translation_state
  run init_add_or_update_lang "en US"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid language code"* ]]
}

@test "record_submodule_update: deduplicates entries" {
  init_translation_state
  record_submodule_update "algorithm"
  record_submodule_update "algorithm"
  [ "${#UPDATES[@]}" -eq 1 ]
  [ "${UPDATES[0]}" = "algorithm" ]
}

@test "record_add_or_update_submodule: deduplicates within lang key" {
  init_translation_state
  init_add_or_update_lang "en"
  record_add_or_update_submodule "en" "algorithm"
  record_add_or_update_submodule "en" "algorithm"
  [ "${add_or_update[en]}" = "algorithm" ]
}

@test "validate_add_or_update_entry: rejects empty value" {
  run validate_add_or_update_entry "en" ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"add_or_update[en] is empty"* ]]
}

@test "validate_add_or_update_entry: rejects invalid submodule token" {
  run validate_add_or_update_entry "en" "libs/foo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid submodule name"* ]]
}

@test "trigger_weblate: skips when add_or_update is empty" {
  load_translation
  init_translation_state
  init_add_or_update_lang "en"
  run trigger_weblate "https://weblate.example" "token" "develop" "[]" "en"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Weblate skipped: no translations to update."* ]]
}

@test "trigger_weblate: fails on invalid submodule name in map" {
  load_translation
  init_translation_state
  add_or_update["en"]="libs/foo"
  run trigger_weblate "https://weblate.example" "token" "develop" "[]" "en"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid submodule name"* ]]
}

@test "record_submodule_fatal: deduplicates entries" {
  init_translation_state
  record_submodule_fatal "algorithm"
  record_submodule_fatal "algorithm"
  [ "${#SUBMODULE_FATAL[@]}" -eq 1 ]
  [ "${SUBMODULE_FATAL[0]}" = "algorithm" ]
}

@test "print_submodule_processing_summary: empty state shows (none) for all buckets" {
  load_lib
  reset_process_globals
  run print_submodule_processing_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"Submodule processing summary"* ]]
  [[ "$output" == *"Successfully updated (0): (none)"* ]]
  [[ "$output" == *"Failed — Type 1"*"(none)"* ]]
  [[ "$output" == *"Failed — processing error (0): (none)"* ]]
  [[ "$output" == *"Skipped — open translation PR (0): (none)"* ]]
}

@test "print_submodule_processing_summary: lists populated buckets" {
  load_lib
  reset_process_globals
  UPDATES=("algorithm")
  META_MISSING=("broken_meta")
  NO_DOC_PATHS=("no_docs")
  ORG_REPO_MISSING=("missing_repo")
  REPO_EXISTS_SKIP=("existing_repo")
  OPEN_PR_SKIP=("open_pr_lib")
  SUBMODULE_FATAL=("broken_meta" "clone_failed")
  run print_submodule_processing_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"Successfully updated (1): algorithm"* ]]
  [[ "$output" == *"Failed — Type 1"*broken_meta* ]]
  [[ "$output" == *"Failed — Type 3"*missing_repo* ]]
  [[ "$output" == *"Failed — processing error (1): clone_failed"* ]]
  [[ "$output" == *"Skipped — Type 2"*no_docs* ]]
  [[ "$output" == *"Skipped — org repo already exists"*existing_repo* ]]
  [[ "$output" == *"Skipped — open translation PR"*open_pr_lib* ]]
}

@test "print_submodule_processing_summary: does not double-list categorized fatal errors" {
  load_lib
  reset_process_globals
  META_MISSING=("broken_meta")
  SUBMODULE_FATAL=("broken_meta" "sync_failed")
  run print_submodule_processing_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"Failed — processing error (1): sync_failed"* ]]
  [[ "$output" != *"processing error (2)"* ]]
}

@test "heartbeat_run_is_stale: stale when no successful run is on record" {
  heartbeat_run_is_stale "" 200000 100000
  heartbeat_run_is_stale "0" 200000 100000
}

@test "heartbeat_run_is_stale: stale when the last success is older than the threshold" {
  heartbeat_run_is_stale 50000 200000 100000
}

@test "heartbeat_run_is_stale: fresh when the last success is within the threshold" {
  ! heartbeat_run_is_stale 150000 200000 100000
}

@test "heartbeat_run_is_stale: at the threshold boundary is still fresh (strict older-than)" {
  ! heartbeat_run_is_stale 100000 200000 100000
}

@test "latest_successful_scheduled_created_at: newest createdAt when rows are out of order" {
  local json got
  json='[
    {"createdAt":"2026-09-13T00:46:09Z","event":"schedule","conclusion":"success"},
    {"createdAt":"2026-09-17T00:40:56Z","event":"schedule","conclusion":"success"},
    {"createdAt":"2026-09-16T00:41:03Z","event":"schedule","conclusion":"success"}
  ]'
  got="$(printf '%s\n' "$json" | latest_successful_scheduled_created_at)"
  [ "$got" = "2026-09-17T00:40:56Z" ]
}

@test "latest_successful_scheduled_created_at: ignores dispatch and non-success rows" {
  local json got
  json='[
    {"createdAt":"2026-09-13T00:46:09Z","event":"schedule","conclusion":"success"},
    {"createdAt":"2026-09-18T00:00:00Z","event":"repository_dispatch","conclusion":"success"},
    {"createdAt":"2026-09-18T01:00:00Z","event":"schedule","conclusion":"failure"},
    {"createdAt":"2026-09-17T00:40:56Z","event":"schedule","conclusion":"success"}
  ]'
  got="$(printf '%s\n' "$json" | latest_successful_scheduled_created_at)"
  [ "$got" = "2026-09-17T00:40:56Z" ]
}

@test "latest_successful_scheduled_created_at: empty array emits nothing" {
  local got
  got="$(printf '%s\n' '[]' | latest_successful_scheduled_created_at)"
  [ -z "$got" ]
}

@test "runs_cover_heartbeat_window: empty array does not cover" {
  ! runs_cover_heartbeat_window '[]' 200000 100000
}

@test "runs_cover_heartbeat_window: oldest run still inside the window does not cover" {
  local json now=2000000 max_age=1000000 fresh
  fresh="$(date -u -d @$((now - 10)) +%Y-%m-%dT%H:%M:%SZ)"
  json="$(printf '{"createdAt":"%s","event":"schedule","conclusion":"success"}\n' "$fresh" | jq -s '.')"
  ! runs_cover_heartbeat_window "$json" "$now" "$max_age"
}

@test "runs_cover_heartbeat_window: oldest run at the window boundary covers" {
  local json now=2000000 max_age=1000000 oldest
  oldest="$(date -u -d @$((now - max_age)) +%Y-%m-%dT%H:%M:%SZ)"
  json="$(printf '{"createdAt":"%s","event":"schedule","conclusion":"success"}\n' "$oldest" | jq -s '.')"
  runs_cover_heartbeat_window "$json" "$now" "$max_age"
}

@test "list_workflow_runs_covering_window: keeps fetching until the window is covered" {
  # shellcheck source=tests/helpers/mock_gh.bash
  source "$BATS_TEST_DIRNAME/helpers/mock_gh.bash"
  install_mock_gh
  local now=2000000 max_age=1000000 i fresh old json got
  fresh="$(date -u -d @$((now - 10)) +%Y-%m-%dT%H:%M:%SZ)"
  old="$(date -u -d @$((now - max_age - 1)) +%Y-%m-%dT%H:%M:%SZ)"
  json='['
  for i in 1 2 3; do
    json+="$(printf '{"createdAt":"%s","event":"repository_dispatch","conclusion":"success"}' "$fresh")"
    json+=','
  done
  json+="$(printf '{"createdAt":"%s","event":"schedule","conclusion":"success"}' "$old")"
  json+=']'
  export MOCK_RUN_LIST_JSON="$json"

  got="$(list_workflow_runs_covering_window testorg/boost-docs-translation sync-translation.yml "$now" "$max_age" 2 10)"
  restore_mock_gh
  [ "$(jq 'length' <<<"$got")" -eq 4 ]
  [ "$(printf '%s\n' "$got" | latest_successful_scheduled_created_at)" = "$old" ]
}

@test "list_workflow_runs_covering_window: fails when max limit is hit before the window is covered" {
  # shellcheck source=tests/helpers/mock_gh.bash
  source "$BATS_TEST_DIRNAME/helpers/mock_gh.bash"
  install_mock_gh
  local now=2000000 max_age=1000000 i fresh json
  fresh="$(date -u -d @$((now - 10)) +%Y-%m-%dT%H:%M:%SZ)"
  json='['
  for i in 1 2 3 4; do
    json+="$(printf '{"createdAt":"%s","event":"repository_dispatch","conclusion":"success"}' "$fresh")"
    [[ "$i" -lt 4 ]] && json+=','
  done
  json+=']'
  export MOCK_RUN_LIST_JSON="$json"

  run list_workflow_runs_covering_window testorg/boost-docs-translation sync-translation.yml "$now" "$max_age" 2 2
  restore_mock_gh
  [ "$status" -eq 1 ]
  [[ "$output" == *"HEARTBEAT_RUN_LIST_MAX"* ]]
}
