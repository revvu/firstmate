#!/usr/bin/env bash
# Live: real fm-spawn.sh + real Herdr lab session + real treehouse; cswap/claude shims in a disposable HOME.
set -u
WT=$(pwd)
EV=/Users/reevuadakroy/.no-mistakes/evidence/01M4VEB7RP2MCJJ3M0STEK9WGN
REALCFG=$HOME/.config
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
UH=$LAB/user-home; SHIM=$LAB/shim; mkdir -p "$UH" "$SHIM"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY
SESSION=$("$WT/bin/fm-herdr-lab.sh" name cswaplive)
echo "lab home: $LAB  herdr session: $SESSION"
cleanup() {
  "$WT/bin/fm-herdr-lab.sh" teardown "$SESSION" >/dev/null 2>&1 && echo "lab herdr session torn down"
  for w in $(cat "$LAB/wts" 2>/dev/null); do HOME=$UH treehouse return --force "$w" >/dev/null 2>&1; done
  chmod -R u+w "$LAB"; rm -rf "$LAB" /tmp/fm-cswap-live /tmp/fm-cswap-live+* /tmp/fm-cswap-refuse*
}
trap cleanup EXIT
# fixture listing: account 1 is the active login but nearly spent; account 2 has most quota
cat > "$LAB/cswap-list.json" <<J
{"schemaVersion":1,"activeAccountNumber":1,"accounts":[
 {"number":1,"email":"active@example.invalid","active":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":80},"sevenDay":{"pct":40},"scoped":[]}},
 {"number":2,"email":"spare+two@example.invalid","active":false,"usageStatus":"ok","usage":{"fiveHour":{"pct":10},"sevenDay":{"pct":30},"scoped":[]}},
 {"number":3,"email":"off@example.invalid","active":false,"disabled":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":0},"sevenDay":{"pct":0},"scoped":[]}}]}
J
cat > "$SHIM/cswap" <<S
#!/usr/bin/env bash
echo "cswap \$*" >> "$LAB/cswap-calls"
case "\$1 \${2:-}" in
 "list --json") cat "$LAB/cswap-list.json";;
 "run "*) [ "\$3" = --require-session ] || exit 1
   d="$UH/.claude-swap-backup/sessions/\$2-\$(jq -r --argjson n "\$2" '.accounts[]|select(.number==\$n)|.email' "$LAB/cswap-list.json" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g')"
   mkdir -p "\$d"; echo '{}' > "\$d/.credentials.json";;
 *) exit 1;;
esac
S
cat > "$SHIM/claude" <<S
#!/usr/bin/env bash
if [ "\$1 \${2:-}" = "auth status" ]; then echo "auth-status CLAUDE_CONFIG_DIR=\${CLAUDE_CONFIG_DIR-unset}" >> "$LAB/claude-checks"; [ -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json" ]; exit; fi
{ echo "CLAUDE_CONFIG_DIR=\${CLAUDE_CONFIG_DIR-unset}"; echo "ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY-unset}"; echo "ARGS=\$*"; } > "$LAB/worker-env"
exec sleep 600
S
chmod +x "$SHIM/cswap" "$SHIM/claude"
export HOME=$UH XDG_CONFIG_HOME=$REALCFG PATH="$SHIM:$PATH"
"$WT/bin/fm-herdr-lab.sh" provision "$SESSION" || { echo provision failed; exit 1; }
export HERDR_SESSION=$SESSION
# project fixture with an origin
P=$LAB/proj; mkdir -p "$P"; git -C "$P" init -q; echo hi > "$P/README.md"; git -C "$P" add .; git -C "$P" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$P" "$P.origin.git"; git -C "$P" remote add origin "file://$P.origin.git"
printf 'claude\n' > "$LAB/config/crew-harness"; printf 'cswap\n' > "$LAB/config/claude-account"
for id in cswap-live cswap-refuse; do mkdir -p "$LAB/data/$id"; printf "# Task\n## Captain's intent\nlive cswap pin check $id\n\n## Firstmate spec\nExercise the cswap pin.\n" > "$LAB/data/$id/brief.md"; done
echo "=== config/claude-account: $(cat $LAB/config/claude-account)"
echo "=== SCENARIO happy: spawn cswap-live (model opus)"
ANTHROPIC_API_KEY=ambient-key CLAUDE_CONFIG_DIR=$LAB/ambient FM_HOME=$LAB FM_SPAWN_NO_GUARD=1 "$WT/bin/fm-spawn.sh" cswap-live "$P" --mode no-mistakes --yolo off --backend herdr --model opus 2>&1 | tail -15
echo "spawn exit ${PIPESTATUS[0]}"
grep -h '^worktree=' "$LAB/state/cswap-live.meta" 2>/dev/null | cut -d= -f2 >> "$LAB/wts"
for i in $(seq 1 30); do [ -s "$LAB/worker-env" ] && break; sleep 1; done
echo "--- cswap calls:"; cat "$LAB/cswap-calls"
echo "--- claude sign-in checks:"; cat "$LAB/claude-checks"
echo "--- worker process env inside the Herdr pane:"; cat "$LAB/worker-env" 2>/dev/null || echo "(worker never started)"
echo "--- real worker process in the pane (ps eww, filtered):"; for pid in $(pgrep -f "claude" ); do e=$(ps eww -o command= -p $pid 2>/dev/null); case "$e" in *"$LAB"*) echo "pid $pid argv: $(ps -o command= -p $pid | cut -c1-160)"; printf "%s\n" "$e" | tr " " "\n" | grep -E "^(CLAUDE_CONFIG_DIR|ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)=" | sed "s/ANTHROPIC_API_KEY=.*/ANTHROPIC_API_KEY=<present>/";; esac; done
echo "--- pane screen:"; "$WT/bin/fm-herdr-lab.sh" run "$SESSION" pane read w1:p2 --source recent --format text 2>&1 | grep -v "^\s*$" | tail -25
echo "--- state/cswap-live.meta:"; cat "$LAB/state/cswap-live.meta" 2>/dev/null | grep -v '^$'
echo "--- Herdr lab panes:"; "$WT/bin/fm-herdr-lab.sh" run "$SESSION" pane list 2>/dev/null | jq -c '.result.panes[]? | {pane_id, label: .label, cwd: .foreground_cwd, agent: .agent}' 2>/dev/null | head
echo "=== SCENARIO refuse: real cswap 0.26.0 in the disposable HOME (no managed accounts)"
rm "$SHIM/cswap"; : > "$LAB/claude-checks"
echo "cswap on PATH: $(command -v cswap) ($(cswap --version))"
FM_HOME=$LAB FM_SPAWN_NO_GUARD=1 "$WT/bin/fm-spawn.sh" cswap-refuse "$P" --mode no-mistakes --yolo off --backend herdr --model claude-fable-5-1 2>&1 | tail -5
echo "spawn exit ${PIPESTATUS[0]}"
echo "state/cswap-refuse.meta exists: $([ -e $LAB/state/cswap-refuse.meta ] && echo yes || echo no); sign-in checks run: $(wc -l < $LAB/claude-checks | tr -d ' ')"
echo "real HOME cswap backup untouched in disposable home: $(ls -A $UH/.claude-swap-backup 2>/dev/null | tr '\n' ' ')"
echo "=== SCENARIO no cswap on PATH"
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/.local/bin' | paste -sd: -)
echo "cswap on PATH: $(command -v cswap || echo none)"
FM_HOME=$LAB FM_SPAWN_NO_GUARD=1 "$WT/bin/fm-spawn.sh" cswap-refuse "$P" --mode no-mistakes --yolo off --backend herdr 2>&1 | tail -5
echo "spawn exit ${PIPESTATUS[0]}"
