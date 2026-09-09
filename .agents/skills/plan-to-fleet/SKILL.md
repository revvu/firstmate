---
name: plan-to-fleet
description: >-
  Turn a locked Lavish (or prose) plan into an implementation fleet: parallel
  slices, exploration vs ship split, and recommended harness/model/effort per
  slice using the standing routing policy. Use when the captain is ready to leave
  Explore/planning and begin Execute, invokes /plan-to-fleet, asks how to
  parallelize a plan, or asks which agent should take which slice.
user-invocable: true
metadata:
  internal: true
---

# plan-to-fleet

Single owner of the Explore → Execute handoff for this captain’s fleet.
Standing matrix: [`docs/routing-policy.md`](../../../docs/routing-policy.md).
Multi-account Claude notes: [`docs/multi-account-quota.md`](../../../docs/multi-account-quota.md).
Dispatch mechanics: `AGENTS.md` section 4, `quota-array-dispatch`, `config/crew-dispatch.json`.

## When to load

- Captain says planning is done / ready to implement / parallelize.
- Lavish plan has stable intent and acceptance criteria.
- `/plan-to-fleet`.
- About to spawn more than one crewmate from one plan without explicit assignments.

Do **not** load for Explore-mode Lavish iteration.

## Hierarchy reminder

- **Opus** — standing Claude model: questions, framing, planning, ordinary judgment, small artifact/Lavish/Paper edits, Claude-lane implementation (pin explicitly).
- **Fable** — substantial design only (real UI/product-surface build or redesign, major system-shape, final taste on a surface actively being built); Opus xhigh is the fallback.
- **Codex** — frontier implement + adversarial review.
- **Cursor** — speed implement (chores, mechanical, ordinary ships, UI fan-out).

## Preconditions

1. Name project + delivery posture.
2. Confirm leaving Explore for Execute.
3. Read the plan artifact.
4. Run `quota-axi --json` once; optionally `cswap list` when Claude slices exist (use `--need fable` only for substantial-design slices).
5. Read `config/crew-dispatch.json` or `docs/examples/crew-dispatch.json`.

## Produce the fleet map

1. **Intent lock** — what ships / out of scope.
2. **Slices** — independent units; serialize only on true semantic dependency.
3. **Per slice** — id, type (`ship`|`scout`|`chore`|`taste`|`fan-out`|`design`), depends-on, recommended harness/model/effort, fallback, definition of done.
4. **Review path** — no-mistakes then CodeRabbit; prefer Codex for review.
5. **Quota note** — Cursor/Codex from quota-axi; Claude slots from cswap when relevant.
   Remember `model:fable` is a named model sub-window bounded by `claude,all_models`, so account-level headroom is not Fable headroom.

| Slice type | Default |
|---|---|
| substantial design / major architecture / active-build taste | Claude Fable xhigh → Opus xhigh |
| ordinary judgment / framing / questions / small artifact edits | Claude Opus high |
| taste / layout polish (shipped surface) | Claude Opus high → Cursor |
| fan-out | Cursor medium → Codex |
| chore / mechanical | Cursor low → Codex |
| ordinary ship | Cursor medium → Codex |
| ambiguous implement | Codex high → Cursor → Claude Opus high |
| review | Codex high → Claude Opus high |

## Captain edit gate

Show the map; wait for approval unless they already said spawn-as-recommended.

## After approval

Spawn via `bin/fm-spawn.sh` with concrete `--harness` / `--model` / `--effort` after section 4 + `quota-array-dispatch`.
Until multi-account Claude dispatch lands, do not claim a specific cswap slot was selected unless you actually launched through `cswap run <n>`.

## Anti-patterns

- Spawning all implementation onto Fable (or onto Claude when Cursor/Codex fit).
- Using Fable for bulk variant generation, small Lavish/Paper document edits, or routine framing.
- Mid-flight `cswap` of a live agent instead of assigning implement work to Cursor/Codex.
- Starting Execute while major product forks are still open — finish Explore or schedule a design scout first.
