# Changelog

All notable changes to the **orchestration contract** of this repository are documented
in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
for **this** repository only. Mirror content tags (`boost-1.90.0-algorithm-zh_Hans`)
are a separate namespace — see [README](README.md#releases) and
[`.github/workflows/assets/README.md`](.github/workflows/assets/README.md#tag-namespaces).

## [Unreleased]

### Fixed

- **`heartbeat.yml`** no longer treats the first row of `gh run list
  --event schedule --status success --limit 1` as the latest successful
  scheduled sync. Those filters use GitHub's search index, whose first page
  is not reliably newest-first, which produced false stale-heartbeat alerts
  while daily **`sync-translation`** was still succeeding. The workflow now
  lists unfiltered runs until they cover **`HEARTBEAT_MAX_AGE_HOURS`**, then
  **`latest_successful_scheduled_created_at`** selects the max `createdAt`
  among successful scheduled runs. Hitting **`HEARTBEAT_RUN_LIST_MAX`** before
  that window is covered fails the check instead of treating a truncated list
  as a missed run.

## [1.1.0] - 2026-07-31

### Added

- JSON Schema for the outbound Weblate add-or-update POST request:
  [weblate-add-or-update.request.schema.json](docs/schemas/weblate-add-or-update.request.schema.json)
  (`organization`, `version`, `extensions`, `add_or_update`).
- Documented Weblate success response bodies in
  [endpoint-contract.md](docs/endpoint-contract.md): HTTP **202** (`task_id`),
  HTTP **200** (`status: "ok"`).
- Lint/CI schema checks via pinned `check-jsonschema` (metaschema + fixture
  validation); bats validates captured Weblate request bodies against the schema
  and asserts success response fields.
- Slack failure notifications for `sync-translation` (via `notify-failure` job)
  and stale-sync alerts for `heartbeat` (shared `notify.sh` + `SLACK_WEBHOOK_URL`
  secret).

### Changed

- Extracted shared dispatch helpers into
  [`scripts/trigger-dispatch-common.sh`](scripts/trigger-dispatch-common.sh)
  (`DEFAULT_REPO`, `DEFAULT_VERSION`, JSON build, `POST …/dispatches`); both
  `trigger-*.sh` wrappers source it.
- Mirror **`create-tag.yml`** bot identity now uses **`set_git_bot_config`** from
  **`env.sh`** / **`lib.sh`** instead of a hardcoded org email.
- Renamed and expanded operator quick reference to
  [GETTING-STARTED.md](docs/GETTING-STARTED.md): end-to-end walkthrough with
  per-step verification and create-tag coverage.
- [endpoint-contract.md](docs/endpoint-contract.md) Outbound Weblate section:
  request schema is now the source of truth for payload fields.
- `scripts/trigger-add-submodules.sh` now requires `--submodules`; the
  `unordered, json` script default is removed so the operator script cannot
  silently diverge from raw API auto-discovery.
- Bats coverage for `scripts/trigger-dispatch-common.sh`, `trigger-add-submodules.sh`,
  and `trigger-start-translation.sh`.
- **`start-translation.yml`** fail-on-empty-discovery success criteria and
  **`start-local`** gate ([#69](https://github.com/cppalliance/boost-docs-translation/pull/69),
  c098a18): **`sync-mirrors`** exits non-zero when **`.gitmodules`** has zero **`libs/`**
  entries (`require_libs_submodules_in_gitmodules`; `Run add-submodules first.`) instead of
  exiting **0** with **`updated_submodules=[]`**. **`start-local`** **`if:`** gates on
  **`sync-mirrors`** job success rather than a non-empty **`updated_submodules`** handoff;
  when **`sync-mirrors`** succeeds with an empty array, **`start-local`** runs and exits
  non-zero with a distinct empty-handoff error instead of silently succeeding.
  Ships as **MINOR** (not **MAJOR**) because the versioned consumer surface—
  **`repository_dispatch`** event types, **`client_payload`** fields, dispatch HTTP contract,
  and shell **0 / 1 / 2** meanings—is unchanged; the prior green-on-misconfiguration paths
  were an implementation defect (silent success on violated dispatch-order preconditions),
  not a documented intentional success criterion operators should have pinned against.

### Fixed

- `build_dispatch_json` in `trigger-dispatch-common.sh`: pass key/value pairs
  positionally via jq `--args` and `$ARGS.positional` instead of building an
  intermediate array.
- Clone and finalize steps now fail fast: **`clone_repo`**, **`sync_translations_branch`**,
  and **`finalize_translations_*`** propagate non-zero status instead of continuing with
  incomplete state.
- **`combine_batch_and_finalize_rc`** collapses all three exit sources—batch
  **`submodule_fatal`**, **`finalize_rc`**, and optional **`weblate_rc`**—with documented
  last-wins priority; **`start-translation.yml`** **`start-local`** delegates to it instead
  of inline collapse logic.
- **`commit_and_push_translations_branch`**: bounded retry (up to 3 attempts) on
  **`--force-with-lease`** rejection with inter-attempt **`fetch`** and
  **`--force-if-includes`** safety ([#70](https://github.com/cppalliance/boost-docs-translation/pull/70));
  **`sync-translation.yml`** **`sync-local`** now routes through the same helper instead of a
  bare **`git push --force-with-lease`**.

## [1.0.0] - 2026-07-07

Initial semver baseline for the orchestration repo. Summarizes the operator and
consumer surface as it stood at this release; routine submodule pointer updates
are not listed.

### Added

- Core workflows: `add-submodules`, `start-translation`, and `sync-translation`
  triggered via `repository_dispatch` or (for sync) daily schedule.
- Local trigger scripts: `scripts/trigger-add-submodules.sh` and
  `scripts/trigger-start-translation.sh`.
- `client_payload` fields for dispatch events: `version`, `submodules`, `lang_codes`
  (`add-submodules`); `version`, `lang_codes`, `extensions` (`start-translation`).
- [Endpoint contract](docs/endpoint-contract.md): GitHub `POST …/dispatches` shapes,
  auth headers, success = HTTP **204**, and outbound Weblate POST contract.
- Weblate integration: `WEBLATE_ENDPOINT_PATH` consolidation, structured HTTP error
  handling, success codes **200** or **202**.
- Shell per-submodule batch return codes **0 / 1 / 2** with workflow job collapse
  rules documented in [ARCHITECTURE §6](docs/ARCHITECTURE.md#6-shell-return-codes)
  (code **2** is never propagated to GitHub Actions step exit).
- Branch and path constants in `.github/workflows/assets/env.sh`:
  `MASTER_BRANCH`, `LOCAL_BRANCH_PREFIX`, `TRANSLATION_BRANCH_PREFIX`,
  `WEBLATE_ENDPOINT_PATH`.
- Mirror asset `create-tag.yml` (copied into library mirrors; produces content tags,
  not orchestration semver).
- Test harness and CI: `make check` (ShellCheck, actionlint, bats suite).
- Operator quick reference: [GETTING-STARTED.md](docs/GETTING-STARTED.md) (formerly OPERATOR.md).

[Unreleased]: https://github.com/cppalliance/boost-docs-translation/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/cppalliance/boost-docs-translation/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/cppalliance/boost-docs-translation/releases/tag/v1.0.0
