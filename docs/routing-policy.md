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

| Tier | Who | Job |
|---|---|---|
| Judgment / design | Claude **Fable** (then strong Claude) | Ask the captain hard questions; design; architecture; taste/layout converge |
| Frontier implement | **Codex** | Smart implementation when the path is mostly decided but still needs a strong coder; adversarial review |
| Speed implement | **Cursor** | Chores, mechanical edits, ordinary ships, UI/Paper fan-out (Cursor has **no effort flag** — omit `effort` in dispatch; optionally pin `--model` like `composer-2.5-fast`) |

**Implementers are Cursor + Codex.** Fable is not the default coder.

## Modes

### Explore (single session, no fleet)

Decisions still open: surface shopping, Paper fan-out, Lavish plan iteration.

| Role | Who |
|---|---|
| Hard questions / framing | Fable (or high-effort Claude) |
| Fast Lavish/Paper edits and many rough variants | Cursor CLI (or Cursor crewmate once dispatched) |
| Final taste converge | Fable |

Do not spawn a big fleet until intent is lockable.

### Execute (First Mate + crew)

Plan locked → `/plan-to-fleet` → spawn.

| Task class | Preferred order |
|---|---|
| Design / architecture / clarifying questions | Fable → Claude high |
| Taste / layout cleanup | Fable → Claude high |
| UI fan-out (rough options) | Cursor → Codex |
| Chore / mechanical | Cursor → Codex |
| Ordinary ship | Cursor → Codex |
| Ambiguous-but-implementable ship | Codex → Cursor → Claude |
| Adversarial review | Codex → Claude |

Done units (Gallopify): merged PR **and** Linear issue closed together when Linear owns the work.
Quality: `no-mistakes` local gate, then CodeRabbit on the PR.

## Auto-route vs propose

- Auto-route when the class is obvious.
- Propose via `plan-to-fleet` when leaving Explore with a multi-slice plan.

## Claude accounts + quota

`quota-axi` sees the **active** Claude account plus Codex + Cursor.
`claude-swap` (`cswap`) owns the multi-account inventory and per-slot usage cache under its data dir (`cache/usage.json`).

Today First Mate does **not** auto-pick Claude slot 1 vs 2 vs 4. See options in the captain conversation / `docs/multi-account-quota.md` when present.
Standing practice until that lands: keep `cswap auto` on the primary; prefer Cursor/Codex for Execute so Claude accounts stay available for Fable judgment; use `cswap run <n>` or mapped secondmates for parallel Claude when needed.

## Weekly matrix edit checklist

1. Edit this file.
2. Mirror into `docs/examples/crew-dispatch.json`.
3. Copy into each home’s `config/crew-dispatch.json`.
4. Smoke one Cursor chore spawn, one Codex implement spawn, one Fable design scout.
