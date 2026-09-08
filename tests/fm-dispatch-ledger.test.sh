#!/usr/bin/env bash
# Public ledger append/summarize: retry safety, incarnation identity and writers.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-dispatch-ledger)
export FM_HOME="$LAB/home" FM_DATA_OVERRIDE="$LAB/home/data"
LEDGER="$ROOT/bin/fm-dispatch-ledger.sh"
mkdir -p "$FM_HOME/state"
META="$FM_HOME/state/task.meta"
STATUS="$FM_HOME/state/task.status"
cat > "$META" <<'EOF'
spawn_gen=s1788820000.1.2
kind=ship
harness=codex
model=frontier
effort=high
mode=no-mistakes
pr=https://github.com/example/repo/pull/123
EOF
printf 'working: started\nfailed: validation error\n' > "$STATUS"
"$LEDGER" append "$META" "$STATUS" auto
"$LEDGER" append "$META" "$STATUS" auto
jq -se 'length == 1 and .[0].outcome == "failed" and .[0].task_id == "task" and .[0].started_at != null and .[0].pr == "https://github.com/example/repo/pull/123"' \
  "$FM_DATA_OVERRIDE/dispatch-ledger.jsonl" >/dev/null
pids=()
for i in $(seq 1 8); do
  sed "s/spawn_gen=.*/spawn_gen=incarnation-$i/" "$META" > "$FM_HOME/state/task-$i.meta"
  "$LEDGER" append "$FM_HOME/state/task-$i.meta" "$STATUS" cancelled &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
jq -se 'length == 9 and ([.[] | select(.outcome == "cancelled")] | length) == 8' \
  "$FM_DATA_OVERRIDE/dispatch-ledger.jsonl" >/dev/null
# Reuse the id with a fresh dispatch generation.
printf 'spawn_gen=new-incarnation\nkind=scout\nharness=cursor\nmode=local-only\n' > "$META"
printf 'done: report ready\n' > "$STATUS"
"$LEDGER" append "$META" "$STATUS" auto
jq -se 'length == 10 and .[-1].outcome == "done" and .[-1].started_at == null and .[-1].kind == "scout"' \
  "$FM_DATA_OVERRIDE/dispatch-ledger.jsonl" >/dev/null
"$LEDGER" summarize | awk -F '\t' '$2=="codex" && $6=="cancelled" && $7==8 {found=1} END {exit !found}'
# A record with no spawn_gen (a home whose backlog gate never stamps one) must
# still append - teardown calls this after its destructive steps, so a refusal
# would strand the task unretirable - and must retry-dedup under the stable
# 'legacy' token.
printf 'kind=ship\nharness=claude\n' > "$FM_HOME/state/oldtask.meta"
"$LEDGER" append "$FM_HOME/state/oldtask.meta" "$STATUS" auto
"$LEDGER" append "$FM_HOME/state/oldtask.meta" "$STATUS" auto
jq -se 'length == 11 and .[-1].task_id == "oldtask" and .[-1].spawn_gen == "legacy" and .[-1].started_at == null and .[-1].outcome == "done"' \
  "$FM_DATA_OVERRIDE/dispatch-ledger.jsonl" >/dev/null
printf '{broken\n' >> "$FM_DATA_OVERRIDE/dispatch-ledger.jsonl"
cp "$FM_DATA_OVERRIDE/dispatch-ledger.jsonl" "$LAB/before"
if "$LEDGER" append "$META" "$STATUS" done 2>/dev/null; then
  echo 'not ok - corrupt ledger accepted' >&2; exit 1
fi
cmp "$LAB/before" "$FM_DATA_OVERRIDE/dispatch-ledger.jsonl"
echo 'ok - outcomes, timestamps, retry deduplication, concurrent writers, reused ids, legacy records without spawn_gen, summary and corrupt-file preservation'
