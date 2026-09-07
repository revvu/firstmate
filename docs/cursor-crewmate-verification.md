# Cursor crewmate status

**Done via upstream merge** (`ce1d472` Merge upstream/main).

This fork now includes Kun Chen’s verified Cursor adapter:

- `bin/fm-cursor-lib.sh`
- `.agents/skills/harness-adapters/references/harness/cursor.md`
- `docs/supervision-protocols/cursor.md`
- `AGENTS.md` verified list includes `cursor`

Standing dispatch prefers Cursor for speed-class work; see `docs/routing-policy.md` and `docs/examples/crew-dispatch.json`.

Remaining gap is **multi-account Claude selection** (cswap × quota-axi), not Cursor verification — see `docs/multi-account-quota.md`.
