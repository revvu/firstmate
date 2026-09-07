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
`claude-swap` owns the multi-account inventory (`cache/usage.json`).

**Execute:** with `config/claude-cswap-auto` on, Claude crewmates auto-pick a healthy slot via `bin/fm-cswap-pick.sh` and launch through `cswap run` (see `docs/multi-account-quota.md`).

**Explore:** not fleet-routed. Global policy in `~/github/dotfiles/home/global-agents.md` tells the judgment model to keep questions here and delegate mechanical Lavish/Paper fan-out to Cursor via `agent -p`.


## Weekly matrix edit checklist

1. Edit this file.
2. Mirror into `docs/examples/crew-dispatch.json`.
3. Copy into each home’s `config/crew-dispatch.json`.
4. Smoke one Cursor chore spawn, one Codex implement spawn, one Fable design scout.
