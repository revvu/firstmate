# Multi-account Claude × quota-axi options

How `cswap` and `quota-axi` relate today, and ways to fold them together.

## What we can already see

| Tool | Sees |
|---|---|
| `quota-axi --json` | Active Claude identity + Codex + Cursor (+ others). One Claude account at a time. |
| `cswap list` / `~/.claude-swap-backup/cache/usage.json` | **All** managed Claude slots: 5h / 7d / Fable % per account, disabled flags, emails. |
| `cswap sequence.json` | Slot order + active account number. |

I (and First Mate) can read both CLIs and both JSON surfaces on this machine. The missing piece is a **single selection procedure** that turns “Claude candidate” into “Claude on slot N with headroom,” then launches with that identity.

## Options (light → heavy)

### A. Thin adapter skill (recommended first)

Keep both tools. Add a firstmate skill (e.g. `claude-account-dispatch`) that:

1. Runs `quota-axi --json` for Cursor/Codex/active-Claude.
2. Reads `cswap list` or `usage.json` for the full Claude pool.
3. When the matched profile wants `harness=claude`, picks the best enabled slot by Fable vs all-models headroom.
4. Spawns via `cswap run <n> -- claude …` (or sets the env `cswap` already uses) instead of bare `claude`.

Pros: no fork of quota-axi; ships in your firstmate fork; uses data you already have.  
Cons: selection logic lives in a skill (judgment), not a hard CLI contract.

### B. `quota-axi` consumer of cswap cache (upstream PR or small fork)

Extend quota-axi to optionally ingest `cswap`’s `usage.json` / sequence and emit **multiple** Claude provider rows (or an `accounts[]` under Claude) with slot ids.

Pros: one `quota-axi --json` snapshot for `quota-array-dispatch`; stays data-only.  
Cons: depends on cswap’s private schema; need coordination with quota-axi maintainer (or maintain a fork).

### C. Fork quota-axi + teach it to poll every cswap credential

Deepest: quota-axi opens each slot’s credentials (cswap configs/credentials) and hits Anthropic usage like cswap does.

Pros: live multi-account semantics in one tool.  
Cons: oauth/keychain complexity, rate-limit fights with cswap’s own poller, highest maintenance.

### D. Secondmates mapped 1:1 to Claude accounts

`cswap map` each secondmate home (or worktree) to a slot. Dispatch “Claude work” to the secondmate whose mapped account has headroom (read from usage.json).

Pros: strong isolation; fits First Mate’s secondmate model.  
Cons: heavier ops; overkill for every small Claude task.

### E. Status quo + Cursor/Codex preference

What the new `crew-dispatch.json` already does: burn Cursor/Codex for implement; reserve Claude/Fable for design. `cswap auto` only protects the primary shell.

Pros: zero new code.  
Cons: still can’t schedule three Claude accounts as parallel Fable workers intelligently.

## Recommendation

Ship **A** next in this fork (skill + spawn wrapper), shaped so it can later call a richer quota-axi (**B**) without rewriting dispatch rules. Only fork quota-axi (**C**) if A/B hit a hard wall (e.g. you need machine-readable multi-Claude in many non-firstmate tools).

Do not put Claude slot numbers into `crew-dispatch.json` rules until a spawn path can honor them.
