# Routing policy (captain fleet)

Portable standing policy for this firstmate fork.
Edit weekly by hand when model rankings change.
Machine-local activation is `config/crew-dispatch.json` (gitignored); keep this doc and `docs/examples/crew-dispatch.json` in sync when you change the matrix.

Related owners:

- `AGENTS.md` section 4 — dispatch intake + quota-array rules
- `.agents/skills/plan-to-fleet` — Lavish planning → implementation fleet
- `.agents/skills/quota-array-dispatch` — profile-array selection
- `.agents/skills/harness-adapters` — verified harness facts (includes `cursor`)

## Model hierarchy

Claude has an explicit **model** axis inside the Claude harness: pin the model on every Claude profile rather than inheriting the machine's ambient default.

| Tier | Who | Job |
|---|---|---|
| Standing Claude | Claude **Opus** (pinned explicitly) | Orchestration, judgment, architecture with a known shape, framing, planning, artifact/Lavish/Paper edits, review, Claude-lane implementation |
| Substantial design | Claude **Fable** (then Opus xhigh) | Real UI or product-surface build/redesign; major architecture or system-shape decisions; final taste converge on a surface actively being built |
| Frontier implement | **Codex** | Smart implementation when the path is mostly decided but still needs a strong coder; adversarial review |
| Speed implement | **Cursor** | Chores, mechanical edits, ordinary ships, UI/Paper fan-out (Cursor has **no effort flag** — omit `effort` in dispatch; optionally pin `--model` like `composer-2.5-fast`) |

**Implementers are Cursor + Codex.** Claude is judgment and reserved design, not the default coder.

**Fable is reserved.** Explicitly not Fable: small edits to an existing Lavish or Paper document, routine framing, ordinary clarifying questions, taste polish on a shipped surface, review, or implementation.

`model:fable` is a named model sub-window bounded by the `claude,all_models` account window, so a provider-level percentage does not describe Fable's headroom and vice versa.
Fable being tight is never a reason to downgrade a genuine substantial-design task below strong-reasoning class; Opus is its fallback (`AGENTS.md` section 4).

## Modes

### Explore (single session, no fleet)

Decisions still open: surface shopping, Paper fan-out, Lavish plan iteration.

| Role | Who |
|---|---|
| Hard questions / framing / ordinary Lavish or Paper edits | Opus (high) |
| Fast Lavish/Paper edits and many rough variants | Cursor CLI (or Cursor crewmate once dispatched) |
| Substantial redesign / final taste on a surface being built | Fable (then Opus xhigh) |

Do not spawn a big fleet until intent is lockable.

### Execute (First Mate + crew)

Plan locked → `/plan-to-fleet` → spawn.

| Task class | Preferred order |
|---|---|
| Substantial design / major architecture / active-build taste | Fable xhigh → Opus xhigh |
| Ordinary judgment / framing / small artifact edits | Opus high |
| Taste / layout polish (shipped surface) | Opus high → Cursor |
| UI fan-out (rough options) | Cursor → Codex |
| Chore / mechanical | Cursor → Codex |
| Ordinary ship | Cursor → Codex |
| Ambiguous-but-implementable ship | Codex → Cursor → Opus |
| Adversarial review | Codex → Opus |
| Agent-driven computer use | Codex high (park if Codex credits are out; no silent Fable fallback) |

Done units (Gallopify): merged PR **and** Linear issue closed together when Linear owns the work.
Quality: `no-mistakes` local gate, then CodeRabbit on the PR.

## Auto-route vs propose

- Auto-route when the class is obvious.
- Propose via `plan-to-fleet` when leaving Explore with a multi-slice plan.

## Claude accounts + quota

`quota-axi` sees the **active** Claude account plus Codex + Cursor.
`claude-swap` owns the multi-account inventory (`cache/usage.json`).

**Execute:** with `config/claude-cswap-auto` on, Claude crewmates auto-pick a healthy slot via `bin/fm-cswap-pick.sh` and launch through `cswap run` (see `docs/multi-account-quota.md`).

**Explore:** not fleet-routed. Global policy in `~/github/dotfiles/home/global-agents.md` tells the judgment model to keep questions here and delegate mechanical Lavish/Paper fan-out to Cursor via `agent -p`.


## Weekly matrix edit checklist

1. Edit this file.
2. Mirror into `docs/examples/crew-dispatch.json`.
3. Copy into each home’s `config/crew-dispatch.json`.
4. Smoke one Cursor chore spawn, one Codex implement spawn, one Fable substantial-design scout.
