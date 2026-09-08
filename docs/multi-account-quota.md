# Pooled Claude accounts

All Claude conversations and crewmates use the same default Claude profile while a separately supervised `cswap auto` process rotates the login underneath them.
Firstmate launches bare Claude with upstream's explicit attribution-off settings and preserves ordinary `CLAUDE_CONFIG_DIR` forwarding.
Leave that variable unset for the default pool; if deliberately using another profile, both cswap and every participating Claude process must use that same profile.
A separately pinned account or profile is outside this pool.
Secondmate account pinning is deferred unless pooling proves insufficient.

## Running the pool

The following invocation was checked against installed `cswap 0.26.0` using `cswap auto --help`:

```sh
cswap auto --model all --threshold 90 --interval 60 --cooldown 300 --no-include-api-key-accounts
```

Run it in a dedicated persistent terminal, or put those exact arguments in a user launchd job's `ProgramArguments` with the absolute installed cswap executable, `RunAtLoad`, `KeepAlive`, and separate stdout/stderr log paths.
Use a single loop per shared profile and supervise that terminal or launchd job directly.
The process runs in the foreground; Firstmate does not create a second loop or own its lifecycle.
The 90% used threshold and 60-second interval are cswap defaults; the five-minute cooldown reduces repeated proactive switches.
`--model all` includes every reported model window, including Fable, and the explicit API-key exclusion prevents per-token fallback.
Inspect decisions without writing credentials or cache state using `cswap auto --once --dry-run --model all --threshold 90 --interval 60 --cooldown 300 --no-include-api-key-accounts`.

The installed cswap implementation acquires Claude Code's primary `.oauth_refresh.lock` and legacy credential lock in Claude Code's order before swapping credentials.
Its [`claude_locks.py`](https://github.com/realiti4/claude-swap/blob/main/src/claude_swap/claude_locks.py) documents the proper-lockfile protocol verified against Claude Code 2.1.218, and `switcher.py` uses that mechanism on the swap path.
This prevents a concurrent refresh from overwriting the newly swapped login.
Under pooling, mid-task quota exhaustion does not call for a Firstmate relaunch: cswap rotates the shared login and existing work continues against it.
The live-agent continuation guarantee is **UNVERIFIED in this fork's worktree**; the post-merge check below must prove it on the installed versions before treating it as an operational guarantee.

## Awareness and notifications

This follows Kun Chen's existing `fm-procevent-quota.sh` architecture: a condition poller produces a durable result through the shared process-event runner and wakes the owning firstmate.
The pooled adapter is `bin/fm-procevent-claude-pool.sh`; its header and `--help` own exact commands, cache schema, state transitions, freshness limit, and reset calculations.
It reads cswap's caches without refreshing them, using every enabled subscription slot and every reported model window to match `--model all`.
Remaining capacity is an equal-account estimate, not a sum of billable tokens: accounts may have different subscription capacities.

```sh
# Read the current pool before applying the reserve gate.
bin/fm-procevent-claude-pool.sh snapshot
# Register notifications in the firstmate home that owns this profile.
bin/fm-procevent-claude-pool.sh arm --interval 60
```

`config/claude-pool-reserve` holds a percent remaining; the default is 10, preserving a small allowance for interactive planning.
The snapshot reports both the sum of remaining percentage points and the normalized percent used by the reserve gate.
Changing that file changes subsequent observations without restarting cswap.

Entering `low` produces the pool-getting-tight notification; entering `exhausted` produces a pool-exhausted notification naming the nearest known reset or explicitly stating that reset data is missing.
`usable_reset` separately reports when all blocking windows on at least one slot will have reset, so a short five-hour reset cannot conceal a later weekly constraint.
Use that applicable recovery time for section 4's one-hour judgment wait, never the nearest unrelated window.
Malformed, failed, missing, or stale usage produces an `unknown` notification rather than a fabricated healthy or exhausted verdict.
These are captain awareness events; the adapter never starts, reroutes, downgrades, or stops work.
The reserve and wait decisions belong only to [`AGENTS.md` section 4](../AGENTS.md#4-harness-and-runtime-dispatch).

The `process-event-sources` skill owns reading, relaying, and acknowledging each exact captured result.
Healthy recovery is captured silently and permits a later reserve crossing to notify again; repeated observations in the same state produce no new event.
The source remains registered after both low and exhausted events, so exhaustion can still be reported after a reserve alert.
To stop notifications, use the adapter's `retire` command; it does not stop cswap.

## Verification boundary

`tests/fm-procevent-claude-pool.test.sh` exercises observed cache semantics and durable notification transitions with isolated fixtures.
The following paths are **UNVERIFIED** until immediately after merge, from the main home:

1. With the captain's approval, run the supervised cswap loop against the shared profile, capture a real account switch while a Claude conversation is running, and verify that conversation continues on the new login without a relaunch.
2. Arm the pooled source under the real watcher, exercise reserve and exhaustion using an isolated fixture cache, and confirm each notification is relayed once, exhaustion names the applicable reset, and acknowledgement survives watcher restart.
3. Spawn one Cursor chore, one Codex implementation, and one Fable scout through the active matrix; verify default-profile use, reserve approval, reset waiting, launch attribution policy, and ledger entries at teardown.

`quota-axi`, `quota-array-dispatch`, and the upstream quota helper libraries remain intact for upstream compatibility; [`routing-policy.md`](routing-policy.md) owns the fork's use of them.
