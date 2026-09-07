# Linear backlog backend

This document is the single owner of the opt-in Linear backlog backend: setup, the queue definition, the state mapping, lifecycle writes, and limits.
When `config/backlog-backend` selects `linear`, the durable work-item queue lives in the Linear workspace so the whole company can see and edit it, and local records keep only live runtime mechanics (running workers, supervision, safety locks) plus captain decision holds.
With the config absent or set to `tasks-axi` or `manual`, nothing in this document applies and behavior is the default local-backlog behavior in [`docs/configuration.md`](configuration.md#backlog-backend-taskstoml--configbacklog-backend).

## Setup

1. Put `linear` (one line) in the home's local, gitignored `config/backlog-backend`.
2. Add `LINEAR_API_KEY=<personal API key>` to the home's local, gitignored `.env`.
3. Run `bin/fm-backlog-linear.sh viewer` and confirm it prints the captain's Linear identity.

The key is read from the environment first, then from `$FM_HOME/.env` (override the file with `FM_LINEAR_ENV_FILE`).
It is sent only as the request `Authorization` header and is never echoed, logged, or committed.
When the key is absent or rejected, every Linear command - including the bearings snapshot under this backend - refuses with a specific credential diagnostic instead of proceeding or rendering an empty queue.
Session-start bootstrap surfaces a missing key as a `MISSING_MANUAL: LINEAR_API_KEY` diagnostic and also requires `curl` and `jq` while this backend is selected.

`config/backlog-backend` is inherited into secondmate homes under the `secondmate-provisioning` contract, but `.env` is not: each secondmate home needs its own `LINEAR_API_KEY` in its own `.env` and refuses Linear operations clearly without it.
Because the queue is workspace-global, every home with the same workspace key reads the same durable queue; which home works an issue remains a firstmate routing decision, and `bin/fm-backlog-handoff.sh` continues to move only local backlog items.

## Queue definition and state mapping

The queue is every non-archived issue across the workspace's teams that is assigned to the key's viewer or unassigned.
Issues assigned to other people are not part of this captain's queue.

Linear workflow-state types map to queue buckets as follows:

| Linear state type | Queue bucket |
| --- | --- |
| `triage`, `backlog`, `unstarted` | queued |
| `started` | in flight |
| `completed` | done |
| `canceled`, `duplicate` | dropped |

An unknown future state type stays visible as queued rather than vanishing.
When a write needs a concrete state (start, done), the issue's own team's lowest-position state of the target type is used, so "In Progress" wins over "In Review" for started.
`bin/fm-linear-lib.sh` owns the exact request mechanics, tuning knobs (`FM_LINEAR_URL`, `FM_LINEAR_TIMEOUT`, `FM_LINEAR_MAX_PAGES`), and the observed API behavior notes; `bin/fm-backlog-linear.sh --help` owns the command syntax.

## Lifecycle writes

Task linkage: dispatching from a Linear issue passes `--linear <ISSUE-ID>` (for example `GAL-8`) to `bin/fm-spawn.sh`, which records `linear=<ISSUE-ID>` in the task's metadata; the lifecycle scripts key every write off that field.
The wired writes, each active only while this backend is selected:

- Dispatch: `fm-spawn.sh` moves the linked issue to its team's started state.
- Ready PR: `fm-pr-check.sh` attaches the canonical PR URL to the linked issue as a link attachment.
- Completion: a non-forced `fm-teardown.sh` moves the linked issue to completed, attaching the PR or noting the report path; a forced teardown deliberately leaves the issue untouched because forced discard is not completion.

Every wired write is best-effort after its primary local action has already succeeded: a failed write prints a loud warning with the exact `bin/fm-backlog-linear.sh` retry command and never fails the spawn, PR arm, or cleanup itself.
Comments posted to Linear are sparse, terse, and factual: at most one comment per real milestone, never step-by-step progress.

## Captain decision holds

`bin/fm-captain-hold.sh` owns the local structured captain-hold mechanics under every backend value (with `bin/fm-decision-hold.sh` remaining a one-release compatibility shim), so compatible `tasks-axi` remains required and the local hold stays the load-bearing record that teardown's completion gate verifies.
While this backend is selected and the origin task (or held task) records a `linear=` link, `hold` additionally mirrors each captain call to the linked issue as the shared `captain-call` label plus one deduplicated comment stating the decision needed, and `answer`/`resolve` posts the recorded decision and clears the label.
The lifecycle mirror passes the decision key through `resolve --key`, so distinct holds with identical decision text remain distinct milestones; direct captain use may omit `--key` to deduplicate on the decision text alone.
The label is kept when other recorded holds on the same origin are still awaiting the captain, mirroring the issue's overall needs-a-decision state.
The mirror reads the origin's live task metadata, so a hold or resolve recorded after that task's cleanup skips the mirror; a failed mirror warns with the exact retry command and never fails the local mechanics.
The `captain-call` label is created on first use when the workspace does not have it yet.

## Reads

- `bin/fm-backlog-linear.sh list` is the queue read (grouped by bucket; `--json` for the normalized rows).
- `bin/fm-bearings-snapshot.sh` sources its queued/gated, landed, and captain-call decision rows from the Linear queue while the in-flight section stays sourced from local runtime records, which remain authoritative for what is actually running; its header owns the exact projection and disclosure contract.
- The session-start digest prints a pointer to the Linear queue above the local records, which then carry only decision holds and any not-yet-migrated items.

## Limits

- The queue read paginates at 100 issues per page and caps at 5 pages by default, reporting a hit cap to stderr; raise `FM_LINEAR_MAX_PAGES` for a larger workspace.
- There is no offline cache: when Linear is unreachable, queue commands fail loudly rather than serving stale state.
- In-flight authority stays local: a Linear issue started by someone else without a local worker appears in the bearings disclosure list, not as local work.
- Hold-label removal on resolve consults the origin's recorded decision-key inventory, so a hold that never went through the completion inventory keeps the label until its own resolve runs.
- Issue creation (`add`) requires `--team <key>` in a multi-team workspace.
