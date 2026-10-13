#!/usr/bin/env bash
# Live Herdr lab driver for the worker-exit-evidence change.
# Drives the real bin/fm-spawn.sh / fm-crew-state.sh / fm-teardown.sh against a
# named non-default fm-lab-* Herdr session (bin/fm-herdr-lab.sh) and a disposable
# marked lab FM_HOME. A tiny `claude` stand-in is the agent process so the spawn
# takes the verified-adapter path (exit capture on) without credentials.
set -u
ROOT=${ROOT:?run from worktree with ROOT set}
EV=${EV:?}
OUT="$EV/herdr-exit-lab-transcript.txt"
: > "$OUT"
log() { printf '%s\n' "$*" | tee -a "$OUT"; }
FAILS=0
check() { if eval "$2"; then log "PASS: $1"; else log "FAIL: $1"; FAILS=$((FAILS+1)); fi; }

unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH TMUX TMUX_PANE
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS

TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-exit-lab.XXXXXX")
LAB="$TMP/home"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SES=$("$HELPER" name exitlab)
export HERDR_SESSION="$SES"
ORIG_PATH=$PATH
cleanup() {
  for wt in "$TMP"/wt-*; do [ -d "$wt" ] || continue; done
  env PATH="$ORIG_PATH" "$HELPER" teardown "$SES" >>"$OUT" 2>&1 && log "lab teardown ok" || log "lab teardown FAILED"
  find "$TMP" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:$ORIG_PATH"
export TREEHOUSE_ROOT="$TMP/treehouse"; mkdir -p "$TREEHOUSE_ROOT"

env PATH="$ORIG_PATH" "$HELPER" provision "$SES" >>"$OUT" 2>&1 || { log "provision failed"; exit 1; }
log "lab session: $SES  lab home: $LAB"

PROJ="$TMP/project"
mkdir -p "$PROJ"; git -C "$PROJ" init -q; echo '# lab' > "$PROJ/README.md"
git -C "$PROJ" add README.md; git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

brief() { mkdir -p "$LAB/data/$1"; printf "# Task\n\n## Captain's intent\n\nLab exit-evidence check %s.\n\n## Firstmate spec\n\nDo nothing.\n\nDelivery contract: mode=no-mistakes\n" "$1" > "$LAB/data/$1/brief.md"; }
spawn() { FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$@" --backend herdr --mode no-mistakes --yolo off 2>&1; }
relaunch() { FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$@" 2>&1; }
crew() { FM_HOME="$LAB" "$ROOT/bin/fm-crew-state.sh" "$1" 2>&1; }
field() { grep "^$3=" "$1/$2.exit" 2>/dev/null | tail -1 | cut -d= -f2-; }
poll() { local n=$(( $1 * 5 )); shift; while [ $n -gt 0 ]; do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; n=$((n-1)); done; return 1; }
has_exit() { [ -n "$(field "$LAB/state" "$1" exit_status)" ]; }

S="$LAB/state"
lab() { env PATH="$ORIG_PATH" "$HELPER" run "$SES" "$@"; }
pane_of() { grep '^herdr_pane_id=' "$S/$1.meta" | tail -1 | cut -d= -f2-; }
agent_status() { lab agent get "$(pane_of "$1")" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }
agent_ready() { case "$(agent_status "$1")" in idle|working|done|blocked) true;; *) false;; esac; }
claude_pid() { lab pane process-info --pane "$(pane_of "$1")" 2>/dev/null | jq -r '.result.process_info.foreground_processes[]? | select((.name//"")=="claude" or (.argv0//"")=="claude" or ((.argv0//"")|test("claude$"))) | .pid' | head -1; }

# ---------- Scenario 1: SIGKILLed worker reports failed on signal 9 ----------
log ""; log "=== S1 killed worker (herdr) ==="
brief killw
o=$(spawn killw "$PROJ" --harness claude); rc=$?; log "spawn rc=$rc"; log "$o" | tail -5
poll 90 agent_ready killw || log "agent never registered"; log "herdr agent status: $(agent_status killw)"
log "record while running:"; cat "$S/killw.exit" >>"$OUT" 2>&1
check "S1 record armed (no exit_status) while agent runs" '[ -f "$S/killw.exit" ] && ! has_exit killw'
check "S1 meta has no exit_capture=off line" '[ -f "$S/killw.meta" ] && ! grep -q "^exit_capture=" "$S/killw.meta"'
c=$(crew killw); log "crew-state before kill: $c"
check "S1 live crew line carries no exit detail" '[ -f "$S/killw.meta" ] && ! printf %s "$c" | grep -q "exit-record\|agent exited"'
P=$(claude_pid killw); log "claude pid: $P"; lab pane process-info --pane "$(pane_of killw)" >>"$OUT" 2>&1; kill -9 "$P"
poll 30 has_exit killw || log "never recorded"
log "record after kill:"; cat "$S/killw.exit" >>"$OUT"
check "S1 exit_status=137 signal=9 abnormal" '[ "$(field $S killw exit_status)" = 137 ] && [ "$(field $S killw exit_signal)" = 9 ] && [ "$(field $S killw exit_disposition)" = abnormal ]'
sleep 2
c=$(crew killw); log "crew-state after kill: $c"
check "S1 crew-state failed · exit-record · signal 9" 'case "$c" in *"state: failed"*"source: exit-record"*"signal 9"*) true;; *) false;; esac'

# ---------- Scenario 4 (adversarial): refused relaunch keeps the evidence ----------
log ""; log "=== S4 refused relaunch preserves failed record ==="
cp "$S/killw.exit" "$TMP/killw.exit.before"
o=$(relaunch killw --relaunch --mode local-only); rc=$?; log "refused relaunch rc=$rc: $(printf %s "$o" | tail -2)"
check "S4 relaunch refused" '[ $rc -ne 0 ]'
check "S4 record byte-identical after refusal" 'cmp -s "$S/killw.exit" "$TMP/killw.exit.before"'
c=$(crew killw); log "crew-state after refused relaunch: $c"
check "S4 still failed · exit-record" 'case "$c" in *"state: failed"*"exit-record"*) true;; *) false;; esac'

# ---------- Scenario 5: accepted relaunch re-arms (no stale failure) ----------
log ""; log "=== S5 relaunch re-arms, old verdict retired ==="
o=$(relaunch killw --relaunch); rc=$?; log "relaunch rc=$rc: $(printf %s "$o" | tail -3)"
poll 90 agent_ready killw || log "relaunched agent never registered"
log "record after relaunch:"; cat "$S/killw.exit" >>"$OUT" 2>&1
check "S5 record re-armed (no exit_status)" '[ -f "$S/killw.exit" ] && ! has_exit killw'
c=$(crew killw); log "crew-state after relaunch: $c"
check "S5 no stale failed verdict" '! printf %s "$c" | grep -q "state: failed"'

# ---------- Scenario 6: teardown removes the record ----------
log ""; log "=== S6 teardown retires record ==="
o=$(FM_HOME="$LAB" "$ROOT/bin/fm-teardown.sh" killw --force 2>&1); rc=$?; log "teardown rc=$rc: $(printf %s "$o" | tail -3)"
check "S6 state/killw.exit removed" '[ ! -e "$S/killw.exit" ]'

# ---------- Scenario 2: clean exit ----------
log ""; log "=== S2 clean exit ==="
brief cleanw
o=$(spawn cleanw "$PROJ" --harness claude); rc=$?; log "spawn rc=$rc"
poll 90 agent_ready cleanw || log "clean agent never registered"; sleep 3; lab pane run "$(pane_of cleanw)" "/exit" >/dev/null; poll 60 has_exit cleanw || log "clean exit never recorded"
log "record:"; cat "$S/cleanw.exit" >>"$OUT" 2>&1
check "S2 exit_status=0 clean" '[ "$(field $S cleanw exit_status)" = 0 ] && [ "$(field $S cleanw exit_disposition)" = clean ]'
sleep 2
c=$(crew cleanw); log "crew-state: $c"
check "S2 not failed, not done, shows clean detail" 'case "$c" in *"state: failed"*|*"state: done"*) false;; *"agent exited cleanly"*) true;; *) false;; esac'

# ---------- Scenario 3: raw launch command records nothing, never reads clean ----------
log ""; log "=== S3 raw launch opt-out ==="
brief raww
o=$(spawn raww "$PROJ" "sh -c 'exit 0'"); rc=$?; log "spawn rc=$rc: $(printf %s "$o" | grep -i 'exit capture')"
sleep 3
check "S3 meta records exit_capture=off" 'grep -qx "exit_capture=off" "$S/raww.meta"'
check "S3 no exit record" '[ ! -e "$S/raww.exit" ]'
c=$(crew raww); log "crew-state: $c"
check "S3 crew-state never claims a clean/failed exit" '! printf %s "$c" | grep -q "exited cleanly\|state: failed"'

log ""; log "TOTAL FAILS: $FAILS"
exit $FAILS
