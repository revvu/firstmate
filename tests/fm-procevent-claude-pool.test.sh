#!/usr/bin/env bash
# Cache semantics and transition capture through the real process-event runner.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-claude-pool)
export FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state"
export CLAUDE_SWAP_HOME="$LAB/swap" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims"
export FM_ROOT_OVERRIDE="$ROOT"
POOL="$ROOT/bin/fm-procevent-claude-pool.sh"
PE="$ROOT/bin/fm-procevent.sh"
mkdir -p "$FM_HOME/config" "$CLAUDE_SWAP_HOME/cache"
runner=
cleanup() {
  "$PE" retire claude-pool >/dev/null 2>&1 || true
  [ -z "$runner" ] || wait "$runner" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
fixture() {
  python3 - "$1" <<'PY'
import datetime as dt
import json
import os
from pathlib import Path
import sys
import time
root=Path(os.environ['CLAUDE_SWAP_HOME'])
now=time.time()
def reset(hours):
    return dt.datetime.fromtimestamp(now+hours*3600,dt.timezone.utc).isoformat()
def account(five,seven,scoped=0):
    return {'fetchedAt':now,'lastGood':{
        'five_hour':{'pct':five,'resets_at':reset(0.5)},
        'seven_day':{'pct':seven,'resets_at':reset(3)},
        'scoped':[{'name':'Fable','pct':scoped,'resets_at':reset(2)}]}}
accounts={'1':account(20,10),'2':account(0,40,60),'3':account(100,100)}
sequence={'accounts':{'1':{},'2':{},'3':{'disabled':True},'4':{'kind':'api_key'}}}
case=sys.argv[1]
if case=='low': accounts.update({'1':account(95,10),'2':account(0,92)})
if case=='edge': accounts.update({'1':account(90,10),'2':account(0,90)})
if case in ('exhausted','missing-reset','tight-weekly'):
    accounts.update({'1':account(100,100),'2':account(0,0,100)})
if case=='tight-weekly': accounts['1']['lastGood']['seven_day']['pct']=95
if case=='missing-reset':
    del accounts['1']['lastGood']['seven_day']['resets_at']
if case=='stale': accounts['1']['fetchedAt']=now-1801
if case=='failed': accounts['1']['lastError']='rate-limited'
if case=='expired': accounts['1']['lastGood']['five_hour']['resets_at']=reset(-1)
if case=='invalid': accounts['1']['lastGood']['five_hour']['pct']=-1
if case=='missing': del accounts['2']
if case=='disabled': sequence['accounts']['2']['disabled']=True
if case=='empty': sequence={'accounts':{}}
if case=='unknown-schema': schema=3
else: schema=2
for path,value in [(root/'sequence.json',sequence),(root/'cache/usage.json',{'schemaVersion':schema,'accounts':accounts})]:
    temp=path.with_suffix('.tmp')
    temp.write_text(json.dumps(value));temp.replace(path)
PY
}
check() { "$POOL" snapshot | jq -e "$1" >/dev/null || { echo "not ok - $1" >&2; exit 1; }; }
fixture healthy
check '.status == "healthy" and .enabled_slots == 2 and .remaining_points == 120 and .remaining_percent == 60'
fixture disabled
check '.enabled_slots == 1 and .remaining_percent == 80'
fixture edge
check '.status == "healthy" and .all_tight == true'
printf '11\n' > "$FM_HOME/config/claude-pool-reserve"
check '.status == "low"'
rm "$FM_HOME/config/claude-pool-reserve"
# FM_CONFIG_OVERRIDE replaces FM_HOME/config entirely: the override's reserve
# is read and the home's reserve is not.
printf '5\n' > "$FM_HOME/config/claude-pool-reserve"
mkdir -p "$LAB/config-override"
printf '11\n' > "$LAB/config-override/claude-pool-reserve"
FM_CONFIG_OVERRIDE="$LAB/config-override" "$POOL" snapshot \
  | jq -e '.status == "low" and .reserve_percent == 11' >/dev/null \
  || { echo 'not ok - FM_CONFIG_OVERRIDE reserve ignored' >&2; exit 1; }
rm "$FM_HOME/config/claude-pool-reserve"
for case in stale failed expired invalid missing empty unknown-schema; do
  fixture "$case"
  check '.status == "unknown"'
done
fixture tight-weekly
expected_reset=$(jq -r '.accounts["2"].lastGood.scoped[0].resets_at | sub("\\+00:00$"; "Z")' "$CLAUDE_SWAP_HOME/cache/usage.json")
check ".status == \"exhausted\" and .usable_reset == \"$expected_reset\""
fixture missing-reset
check '.status == "exhausted" and .usable_reset == null and .nearest_reset != null'
printf 'garbage\n' > "$FM_HOME/config/claude-pool-reserve"
check '.status == "unknown"'
rm "$FM_HOME/config/claude-pool-reserve"
echo 'ok - used percentages, scoped bottlenecks, disabled/API slots, boundary, reserve config override, missing resets and uncertainty'

# Real captures, not a fake adapter marker: recovery is silent and a second
# runner holds while the state is unchanged, even after handled acknowledgement.
fixture healthy
"$POOL" arm --interval 0.05 >/dev/null
"$PE" start claude-pool > "$LAB/first.out"
[ -f "$FM_HOME/state/procevent-inbox/claude-pool.1.handled" ]
"$PE" start claude-pool > "$LAB/second.out" &
runner=$!
sleep 0.2
kill -0 "$runner"
[ ! -f "$FM_HOME/state/procevent-inbox/claude-pool.2.result" ]
fixture low
wait_for_capture() {
  local seq=$1 i
  for i in $(seq 1 100); do
    [ ! -f "$FM_HOME/state/procevent-inbox/claude-pool.$seq.result" ] || return 0
    sleep 0.05
  done
  echo "not ok - missing capture $seq" >&2
  return 1
}
wait_for_capture 2
wait "$runner"; runner=
[ "$("$PE" classify "$FM_HOME/state/procevent-inbox/claude-pool.2.result")" = low ]
"$PE" handled claude-pool 2 >/dev/null
"$PE" start claude-pool > "$LAB/third.out" &
runner=$!
sleep 0.2
kill -0 "$runner"
[ ! -f "$FM_HOME/state/procevent-inbox/claude-pool.3.result" ]
fixture exhausted
wait_for_capture 3
wait "$runner"; runner=
jq -e '.status == "exhausted" and (.message | contains("nearest reset:")) and .nearest_reset < .usable_reset' \
  "$FM_HOME/state/procevent-inbox/claude-pool.3.result" >/dev/null
[ -f "$FM_HOME/state/procevent/claude-pool.source" ]
fixture healthy
"$PE" start claude-pool > "$LAB/recovery.out"
[ -f "$FM_HOME/state/procevent-inbox/claude-pool.4.handled" ]
fixture low
"$PE" start claude-pool > "$LAB/recross.out"
[ "$("$POOL" classify "$FM_HOME/state/procevent-inbox/claude-pool.5.result")" = low ]
[ "$(wc -l < "$FM_HOME/state/.wake-queue" | tr -d ' ')" -ge 3 ]
echo 'ok - reserve fires once, exhaustion follows with reset, recovery permits a new crossing'
