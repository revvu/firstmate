# Evidence: fm-pr-check resolves CONFIG for linear-linked tasks

Change under test: `0ffd857` (define `CONFIG` in `bin/fm-pr-check.sh`) + `cd6a931` (hermetic regression test), on branch `fm/fm-pr-check-config-fix`.

Fixture (from the new regression test `test_linear_linked_check_resolves_config`): a task spawned with `--linear` (`linear=GAL-8` in the task meta, `linear` backlog backend selected), `fm-pr-check.sh` invoked with **no inherited `CONFIG`, `FM_CONFIG_OVERRIDE`, or `LINEAR_API_KEY`** — exactly the live condition reported on 2026-09-07.

## 1. Reported crash reproduced at base commit (92d9db5)

`bin/fm-pr-check.sh` reverted to the base version, same fixture invocation:

```
=== exit code: 0
=== stdout:
(empty — the merge poll was never armed)
=== stderr:
.../bin/fm-pr-check.sh: line 162: CONFIG: unbound variable
```

The script dies on the unset `$CONFIG` reference (line 162 pre-fix, line 163 post-fix since the fix adds a line above it) before arming the merge poll — matching the live report.

## 2. Fixed behavior at target commit (cd6a931)

Same fixture invocation against the fixed script:

```
=== exit code: 0
=== stdout:
armed: state/task-a.check.sh
=== stderr:
fm-linear: LINEAR_API_KEY is missing - add LINEAR_API_KEY=<key> to .../home/.env (see docs/linear-backend.md)
fm-linear: LINEAR_API_KEY is missing - add LINEAR_API_KEY=<key> to .../home/.env (see docs/linear-backend.md)
warning: could not attach the PR to Linear issue GAL-8; retry with: bin/fm-backlog-linear.sh attach-pr GAL-8 https://github.com/example/repo/pull/42
```

The merge poll arms, the Linear attach path is reached with `CONFIG` resolved from `FM_HOME`, and the missing-key refusal confirms the test is hermetic (`-u LINEAR_API_KEY` seals it — no ambient key, no network; review decision `test-not-hermetic-linear-key` verified applied).

## 3. Regression test fails before the fix, passes after

Single-test run of `test_linear_linked_check_resolves_config`:

- Against base `bin/fm-pr-check.sh`:
  ```
  not ok - linear-linked fm-pr-check did not arm the poll
  ```
- Against fixed `bin/fm-pr-check.sh`:
  ```
  ok - fm-pr-check resolves CONFIG for a linear-linked task without an inherited CONFIG
  ```

## 4. Containing suite

Full `tests/fm-pr-check-security.test.sh` at the target commit: all 28 tests `ok`, including the new test.

Note: two earlier full-file runs each had one *different* pre-existing watcher-loop test fail with an empty error (`test_merged_poll_retires_once` once, the merged-poll-upward test once); both run **before** the new test in file order, exercise code untouched by this diff, pass 3/3 in isolation, and did not reproduce in three subsequent instrumented full runs (all watcher exit codes 0). Pre-existing, load-sensitive flakiness — cause undetermined (suspected but unconfirmed: the 10s `alarm` watchdog in `run_watcher_bounded`).
