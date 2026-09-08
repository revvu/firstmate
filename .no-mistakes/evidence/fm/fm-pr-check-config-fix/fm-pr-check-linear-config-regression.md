# fm-pr-check --linear CONFIG crash: fail-before / pass-after evidence

Reported live crash (2026-09-07): `bin/fm-pr-check.sh` referenced `$CONFIG` without defining it,
so any task spawned with `--linear` crashed before arming the merge poll unless the caller passed
`CONFIG=<home>/config` in the environment.

Method: the new regression test `test_linear_linked_check_resolves_config`
(tests/fm-pr-check-security.test.sh) was run in isolation via a temporary single-test driver,
first against the base-commit (92d9db5, unfixed) `bin/fm-pr-check.sh`, then against the fixed
(d113d3c) version. The test invokes the real `fm-pr-check.sh` binary with
`env -u CONFIG -u FM_CONFIG_OVERRIDE -u LINEAR_API_KEY` — exactly the live-crash condition
(no inherited CONFIG workaround).

## 1. Base (unfixed) — regression test FAILS, reproducing the exact reported crash

```
=== BASE (unfixed) fm-pr-check.sh: regression test run ===
not ok - linear-linked fm-pr-check did not arm the poll
--- captured fm-pr-check stderr (.../linear-pr-check-config/stderr):
/Users/reevuadakroy/.no-mistakes/worktrees/.../bin/fm-pr-check.sh: line 162: CONFIG: unbound variable
driver exit code: 1
```

## 2. Fixed (target commit) — regression test PASSES, poll arms, Linear attach path reached

```
=== FIXED fm-pr-check.sh: regression test run ===
ok - fm-pr-check resolves CONFIG for a linear-linked task without an inherited CONFIG
--- fm-pr-check stdout (.../linear-pr-check-config/stdout):
armed: state/task-a.check.sh
--- fm-pr-check stderr (.../linear-pr-check-config/stderr):
fm-linear: LINEAR_API_KEY is missing - add LINEAR_API_KEY=<key> to .../home/.env (see docs/linear-backend.md)
fm-linear: LINEAR_API_KEY is missing - add LINEAR_API_KEY=<key> to .../home/.env (see docs/linear-backend.md)
warning: could not attach the PR to Linear issue GAL-8; retry with: bin/fm-backlog-linear.sh attach-pr GAL-8 https://github.com/example/repo/pull/42
driver exit code: 0
```

The end-user experience is restored: the merge poll arms (`armed: state/task-a.check.sh`) and the
best-effort Linear attach path runs (warning instead of crash when no API key is present), with no
`CONFIG=` environment workaround.

## 3. Full suite at target commit

`bash tests/fm-pr-check-security.test.sh` → exit 0, 28 ok / 0 not ok
(includes `test_linear_linked_check_resolves_config` in its permanent position).

The fix itself: `bin/fm-pr-check.sh:15` now defines
`CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"`, matching how every other caller of
`fm_linear_backend_selected` resolves it.
