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

- **Fable** — questions, design, architecture, taste converge.
- **Codex** — frontier implement + adversarial review.
- **Cursor** — speed implement (chores, mechanical, ordinary ships, UI fan-out).

## Preconditions

1. Name project + delivery posture.
2. Confirm leaving Explore for Execute.
3. Read the plan artifact.
4. Run `quota-axi --json` once; optionally `cswap list` when Claude/Fable slices exist.
5. Read `config/crew-dispatch.json` or `docs/examples/crew-dispatch.json`.

## Produce the fleet map

1. **Intent lock** — what ships / out of scope.
2. **Slices** — independent units; serialize only on true semantic dependency.
3. **Per slice** — id, type (`ship`|`scout`|`chore`|`taste`|`fan-out`|`design`), depends-on, recommended harness/model/effort, fallback, definition of done.
4. **Review path** — no-mistakes then CodeRabbit; prefer Codex for review.
5. **Quota note** — Cursor/Codex from quota-axi; Claude slots from cswap when relevant.

| Slice type | Default |
|---|---|
| design / architecture / questions | Claude Fable high |
| taste / layout | Claude Fable high |
| fan-out | Cursor medium → Codex |
| chore / mechanical | Cursor low → Codex |
| ordinary ship | Cursor medium → Codex |
| ambiguous implement | Codex high → Cursor → Claude |
| review | Codex high |

## Captain edit gate

Show the map; wait for approval unless they already said spawn-as-recommended.

## After approval

Spawn via `bin/fm-spawn.sh` with concrete `--harness` / `--model` / `--effort` after section 4 + `quota-array-dispatch`.
Until multi-account Claude dispatch lands, do not claim a specific cswap slot was selected unless you actually launched through `cswap run <n>`.

## Anti-patterns

- Spawning all implementation onto Fable.
- Using Fable for bulk variant generation.
- Mid-flight `cswap` of a live agent instead of assigning implement work to Cursor/Codex.
- Starting Execute while major product forks are still open — finish Explore or schedule a design scout first.
