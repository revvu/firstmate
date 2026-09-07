#!/usr/bin/env bash
# fm-cswap-pick.sh — choose a claude-swap account slot from last-known usage.
#
# Data-only. Does not launch Claude, mutate the active login, or recommend a
# harness. Firstmate's claude-account-dispatch skill and fm-spawn (when
# config/claude-cswap-auto is on) consume this output.
#
# Usage:
#   fm-cswap-pick.sh [--need fable|general] [--json]
#   fm-cswap-pick.sh --help
#
# Exit 0 with a pick, 2 when no enabled account is usable, 1 on usage errors.
set -euo pipefail

NEED=general
JSON=0
ROOT="${CLAUDE_SWAP_HOME:-$HOME/.claude-swap-backup}"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --need) NEED=${2:-}; shift 2 ;;
    --need=*) NEED=${1#--need=}; shift ;;
    --json) JSON=1; shift ;;
    --root) ROOT=${2:-}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown arg: $1" >&2; exit 1 ;;
  esac
done

case "$NEED" in fable|general) ;; *)
  echo "error: --need must be fable or general" >&2
  exit 1
esac

SEQ="$ROOT/sequence.json"
USAGE="$ROOT/cache/usage.json"
[ -f "$SEQ" ] || { echo "error: missing $SEQ (is claude-swap installed and accounts added?)" >&2; exit 1; }
[ -f "$USAGE" ] || { echo "error: missing $USAGE (run cswap list once to refresh usage)" >&2; exit 1; }

# shellcheck disable=SC2016
result=$(NEED="$NEED" SEQ="$SEQ" USAGE="$USAGE" python3 - <<'PY'
import json, os, sys

need = os.environ["NEED"]
seq = json.loads(open(os.environ["SEQ"]).read())
usage = json.loads(open(os.environ["USAGE"]).read())
accounts = seq.get("accounts") or {}
active = str(seq.get("activeAccountNumber") or "")
rows = usage.get("accounts") or {}

def score(slot):
    row = rows.get(str(slot))
    if not row:
        return None
    meta = accounts.get(str(slot)) or {}
    if meta.get("disabled"):
        return None
    lg = row.get("lastGood") or {}
    five = (lg.get("five_hour") or {}).get("pct")
    seven = (lg.get("seven_day") or {}).get("pct")
    fable = None
    for s in lg.get("scoped") or []:
        if (s.get("name") or "").lower() == "fable":
            fable = s.get("pct")
            break
    if need == "fable":
        if fable is None:
            return None
        parts = [p for p in (fable, five, seven) if isinstance(p, (int, float))]
        return min(parts) if parts else None
    parts = [p for p in (five, seven) if isinstance(p, (int, float))]
    return min(parts) if parts else None

cands = []
for slot, meta in accounts.items():
    if meta.get("disabled"):
        continue
    sc = score(slot)
    if sc is None:
        continue
    cands.append({
        "slot": str(slot),
        "email": meta.get("email") or "",
        "org": meta.get("organizationName") or "",
        "score": float(sc),
        "active": str(slot) == active,
    })

if not cands:
    print("NO_PICK", file=sys.stderr)
    sys.exit(2)

cands.sort(key=lambda c: (-c["score"], c["active"], int(c["slot"])))
pick = cands[0]
pick["need"] = need
pick["activeAccount"] = active
pick["candidates"] = [
    {"slot": c["slot"], "email": c["email"], "score": c["score"], "active": c["active"]}
    for c in cands
]
print(json.dumps(pick, separators=(",", ":")))
PY
) || {
  ec=$?
  if [ "$ec" -eq 2 ]; then
    echo "error: no enabled claude-swap account with usable last-known usage for need=$NEED" >&2
    exit 2
  fi
  exit "$ec"
}

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$result"
  exit 0
fi

slot=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["slot"])')
email=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["email"])')
score=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin)["score"])')
active=$(printf '%s' "$result" | python3 -c 'import json,sys; print("yes" if json.load(sys.stdin)["active"] else "no")')
printf 'slot=%s email=%s score=%s active=%s need=%s\n' "$slot" "$email" "$score" "$active" "$NEED"
