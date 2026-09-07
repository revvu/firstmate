# Multi-account Claude × quota-axi

How `cswap` and `quota-axi` relate, and what this fork implements.

## What each tool sees

| Tool | Sees |
|---|---|
| `quota-axi --json` | Active Claude identity + Codex + Cursor. One Claude account at a time. |
| `cswap` / `~/.claude-swap-backup/cache/usage.json` | All managed Claude slots: 5h / 7d / Fable % per account, disabled flags. |
| `bin/fm-cswap-pick.sh` | Reads cswap usage + sequence; prints best enabled slot for `--need fable\|general`. |

## Option A (shipped here)

Thin adapter — keep both tools; select Claude **slot** after harness is already Claude.

1. `bin/fm-cswap-pick.sh` — data-only picker.
2. `config/claude-cswap-auto` — when present, `fm-spawn` auto-picks a slot for `harness=claude` and wraps launch as `cswap run <slot> -- <claude-args>` (does not change the captain’s default login).
3. `FM_CLAUDE_CSWAP_SLOT=<n>` — force a slot for one spawn.
4. Skill `claude-account-dispatch` — procedure / overrides / debugging.

Harness choice remains `crew-dispatch.json` + `quota-array-dispatch` (Cursor / Codex / Claude).
Slot choice is only for Claude crewmates.

## Explore vs Execute

| Mode | Who routes |
|---|---|
| Explore (plain Claude/Codex chat) | `~/github/dotfiles/home/global-agents.md` — judgment stays; Cursor via `agent -p` for mechanical Lavish/Paper |
| Execute (First Mate spawn) | `crew-dispatch.json` + optional `claude-cswap-auto` |

Crew-dispatch never runs inside a plain Explore chat.

## Later options (not built)

- **B** — quota-axi emits multi-Claude rows from cswap cache (upstream PR or small fork).
- **C** — quota-axi polls every cswap credential (heavy).
- **D** — secondmates mapped 1:1 to Claude accounts.

Prefer B only if many non-firstmate tools need the same multi-Claude snapshot.
