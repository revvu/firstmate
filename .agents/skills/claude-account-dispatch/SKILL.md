---
name: claude-account-dispatch
description: >-
  Pick a claude-swap account slot for Claude crewmates using cswap usage plus
  quota-axi context. Use before spawning harness=claude, when enabling
  config/claude-cswap-auto, or when the captain asks which Claude account should
  run a task.
user-invocable: false
metadata:
  internal: true
---

# claude-account-dispatch

Owner of **which Claude account** runs a Claude crewmate.
Does not choose harness (that is crew-dispatch + quota-array-dispatch).
Does not change the captain's default login.

Standing background: [`docs/multi-account-quota.md`](../../../docs/multi-account-quota.md).

## When to load

- Before `fm-spawn` with `harness=claude` (or a profile array that may resolve to Claude).
- When the captain asks which Claude account / slot to use.
- When debugging why a Claude crewmate hit limits while another account still had runway.

## Procedure

1. Confirm `cswap` is on PATH and `~/.claude-swap-backup/sequence.json` plus `cache/usage.json` exist (refresh with `cswap list` if usage looks stale).
2. Decide need from the **resolved concrete spawn model**, never from the task class — `fm-spawn` derives it the same way (`bin/fm-spawn.sh`: model matching `*fable*` -> `fable`, every other model -> `general`), and the manual path must agree with it:
   - `fable` when the resolved `--model` is Fable.
   - `general` for every other resolved model, including Opus.

   Resolve the model first via `crew-dispatch.json`. A substantial-design slice whose Fable window is exhausted falls back to Opus xhigh, so its need is `general`. `general` keys on the **window, not the slot**: the picker ranks every enabled slot by its general (5h / 7d) headroom and ignores the Fable scope entirely, so a slot that also carries a Fable scope stays eligible and wins whenever its 5h / 7d headroom is best.
3. Run `"$FM_ROOT/bin/fm-cswap-pick.sh" --need <need> --json` and show the pick (slot, email, score, whether it is already the active login).
4. Launch path:
   - **Preferred:** let `fm-spawn` wrap via auto config — ensure `config/claude-cswap-auto` exists (any content), then spawn normally with `--harness claude`. Spawn prints `info: claude-cswap-auto selected slot=…`.
   - **Override:** set `FM_CLAUDE_CSWAP_SLOT=<n>` for one spawn to force a slot.
   - **Disable for one home:** remove `config/claude-cswap-auto`.
5. Still run `quota-axi --json` for Cursor/Codex/active-Claude when choosing among harnesses; cswap pick only applies after the harness is Claude.

## What this does not do

- Mid-flight swap of a live Claude pane (that still strands work — assign a fresh crewmate on another slot instead).
- Explore-mode Cursor delegation (that is `~/github/dotfiles/home/global-agents.md`, not this skill).
- Putting slot numbers inside `crew-dispatch.json` rules.

## Failure behavior

If the picker exits 2, report no usable enabled account for that need and either spawn bare Claude (captain default) with an explicit warning or wait for the captain — do not invent a slot.
