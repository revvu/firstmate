# Cursor crewmate status

This fork includes Kun Chen's verified Cursor adapter and its existing runtime integration.
The authoritative launch and capability reference is [`harness-adapters/references/harness/cursor.md`](../.agents/skills/harness-adapters/references/harness/cursor.md), with live evidence in [`verification/runtime-backends.md`](verification/runtime-backends.md).

The task-class matrix in [`examples/crew-dispatch.json`](examples/crew-dispatch.json) assigns Cursor speed work; [`routing-policy.md`](routing-policy.md) owns the rationale and review workflow.
Claude capacity now uses the shared-profile pool described in [`multi-account-quota.md`](multi-account-quota.md).
The remaining validation is the post-merge pool and three-lane smoke pass listed there.
Cursor's per-launch no-co-author instruction is a model instruction, not a commit rejection mechanism; its harness reference owns that limitation.
