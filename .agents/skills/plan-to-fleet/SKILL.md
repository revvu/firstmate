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
Standing matrix: [`docs/examples/crew-dispatch.json`](../../../docs/examples/crew-dispatch.json).
Rationale and weekly review: [`docs/routing-policy.md`](../../../docs/routing-policy.md).
Multi-account Claude notes: [`docs/multi-account-quota.md`](../../../docs/multi-account-quota.md).
Dispatch mechanics: the fork override in `AGENTS.md` section 4 and `config/crew-dispatch.json`.

## When to load

- Captain says planning is done / ready to implement / parallelize.
- Lavish plan has stable intent and acceptance criteria.
- `/plan-to-fleet`.
- About to spawn more than one crewmate from one plan without explicit assignments.

Do **not** load for Explore-mode Lavish iteration.

## Hierarchy reminder

- **Fable** - questions, design, architecture, taste converge.
- **Codex** - frontier implement + adversarial review.
- **Cursor** - speed implement (chores, mechanical, ordinary ships, UI fan-out).

## Preconditions

1. Name project + delivery posture.
2. Confirm leaving Explore for Execute.
3. Read the plan artifact.
4. For Claude/Fable slices, read the pool snapshot and apply section 4's reserve gate; optional `quota-axi` awareness uses default TOON first, with JSON only for unresolved structural ambiguity.
5. Read `config/crew-dispatch.json` or `docs/examples/crew-dispatch.json`.

## Produce the fleet map

1. **Intent lock** - what ships / out of scope.
2. **Slices** - independent units; serialize only on true semantic dependency.
3. **Per slice** - id, type (`ship`|`scout`|`chore`|`taste`|`fan-out`|`design`), depends-on, recommended harness/model/effort, fallback, definition of done.
4. **Review path** - no-mistakes then CodeRabbit; prefer Codex for review.
5. **Pool note** - report the reserve gate and applicable reset wait from section 4; quota never changes the assigned lane.

Read slice assignments directly from the matrix instead of keeping a second table here.
Candidate arrays are strict preference order for hard errors only; omit Cursor effort.

## Captain edit gate

Show the map; wait for approval unless they already said spawn-as-recommended.

## After approval

Spawn via `bin/fm-spawn.sh` with the concrete profile after applying section 4's fork override.
Omit `--effort` for Cursor and use the shared default profile for Claude.

## Anti-patterns

- Spawning all implementation onto Fable.
- Using Fable for bulk variant generation.
- Rerouting judgment work automatically because quota is low.
- Starting Execute while major product forks are still open - finish Explore or schedule a design scout first.
