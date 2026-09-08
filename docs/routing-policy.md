# Routing policy for this fork

The task-class matrix has one owner: [`examples/crew-dispatch.json`](examples/crew-dispatch.json).
Activate it in each home's private `config/crew-dispatch.json` after review.
The fork override in [`AGENTS.md` section 4](../AGENTS.md#4-harness-and-runtime-dispatch) owns selection, reserve approval, and reset waiting.
The upstream quota tools remain available for compatibility; they do not arbitrate this fork's dispatches.

## Rationale and handoff

Keep open product, architecture, and taste decisions on Fable because judgment is the task's central requirement.
Use Codex for frontier implementation and adversarial review, and Cursor for speed work once the intended change is clear.
Availability does not change those assignments.
An ordered alternative is for a concrete hard launch error such as a proven unsupported model or unusable credential, never low headroom, a rate-limit reset, or missing quota data.
A hard backend error remains a blocker under section 4; candidate alternatives do not authorize switching runtime backends.
Judgment work never crosses to another agent without the captain's explicit choice.

During Explore, keep questions and final taste convergence in the judgment conversation while Cursor produces mechanical edits or rough variants.
A locked multi-slice plan hands off through [`plan-to-fleet`](../.agents/skills/plan-to-fleet/SKILL.md).
An obvious single task can be routed directly from the matrix.
Cursor profiles omit `effort` because the CLI has no separate effort flag.

## Pool awareness

[`multi-account-quota.md`](multi-account-quota.md) owns the pooled Claude setup, cache interpretation, and live verification boundaries.
Before new Claude dispatches, inspect `bin/fm-procevent-claude-pool.sh snapshot` and apply section 4's reserve gate; do not rely on whether a notification was already delivered.
A missing or stale observation is uncertainty to report, never a reason to select another lane.
`quota-axi` remains optional awareness for other providers: read its default TOON first and request JSON only for an unresolved structural ambiguity.
Neither that output nor pool pressure changes the matrix.

## Weekly matrix review

1. Run `bin/fm-dispatch-ledger.sh summarize` in each owning home to summarize the last seven days of retired dispatches, including failures and cancellations.
2. Inspect the underlying `data/dispatch-ledger.jsonl` entries and their PR links for quality evidence before proposing matrix changes.
3. Edit only `docs/examples/crew-dispatch.json` for task-class assignments; update rationale here only when the rationale changes.
4. Copy the approved example into each home's private `config/crew-dispatch.json`.
5. Smoke one Cursor chore, one Codex implementation, and one Fable design scout, subject to the reserve gate.

The ledger helper owns its schema, timestamp limitations, and retry behavior in its header and `--help`.
A secondmate is a persistent supervisor rather than a dispatched task; review its own home's task ledger alongside the primary home's ledger.
