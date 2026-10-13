# Routing policy (captain fleet)

The standing dispatch matrix for this fork's fleet, expressed in the upstream crew-dispatch schema that [`docs/configuration.md`](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) owns.
The machine-readable copy is [`docs/examples/crew-dispatch.fleet.json`](examples/crew-dispatch.fleet.json); activate it by copying that file into a home's gitignored `config/crew-dispatch.json`.
`tests/fm-crew-dispatch-fleet.test.sh` drives the shipped file through bootstrap's validator and pins the matrix below, so edit the JSON, this table, and that test together.

## Model hierarchy

| Tier | Who | Job |
| --- | --- | --- |
| Judgment | Claude **Fable** (`claude-fable-5-1`), then high-effort Opus | Design, architecture, and the clarifying questions the captain must answer |
| Frontier implement | **Codex** | Big or ambiguous implementation, ordinary ships, adversarial and no-mistakes review |
| Speed implement | **Cursor** (`cursor-agent`) | Chores, mechanical edits, UI/Paper/Lavish fan-out |
| Standing default | Claude **Opus** (pinned) | Anything no rule covers |

Every Claude profile pins its model; nothing inherits the machine's ambient default.
Cursor has no effort flag, so Cursor profiles carry none.

## Matrix

| Task class | Profiles, in quota-array order |
| --- | --- |
| Design, architecture, clarifying questions | Fable high, then Opus high |
| Fan-out (rough variants, settled bulk edits) | Cursor, then Codex medium |
| Chore (docs, CI hygiene, renames, formatting, bumps, one-file fixes) | Cursor, then Codex low |
| Frontier implementation (ambiguous multi-file work, risky refactors) | Codex high, then Opus high |
| Ordinary ship (clear acceptance criteria) | Codex medium, then Cursor |
| Code review (adversarial, no-mistakes, second opinion) | Codex high, then Opus high |
| No rule matches | Opus |

Each array is resolved through `quota-array-dispatch`; a tight Fable window falls back to Opus, never to a speed-class harness.

## Claude accounts

`config/claude-account` set to `cswap` makes every Claude worker launch on the claude-swap account with the most remaining quota, in that account's own cswap session profile; [`docs/configuration.md` "Worker account pin"](configuration.md#worker-account-pin-configclaude-account-configpi-account) owns the contract.
The captain's default login, and any `cswap auto` loop rotating it, is left alone.
