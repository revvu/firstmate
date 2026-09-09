# Cursor crewmate status

**Done via upstream merge** (`ce1d472` Merge upstream/main).

This fork now includes Kun Chen’s verified Cursor adapter:

- `bin/fm-cursor-lib.sh`
- `.agents/skills/harness-adapters/references/harness/cursor.md`
- `docs/supervision-protocols/cursor.md`
- `AGENTS.md` verified list includes `cursor`

Standing dispatch prefers Cursor for speed-class work; see `docs/routing-policy.md` and `docs/examples/crew-dispatch.json`.

Multi-account Claude slot selection (cswap × quota-axi) has since shipped too — see `docs/multi-account-quota.md` for what is built and what is not.
