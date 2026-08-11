#!/usr/bin/env bash
# tests/fm-exit-capture-e2e.test.sh - end-to-end proof that firstmate records and
# reports WHY a launched agent stopped.
#
# This is the case the instrumentation exists for, driven for real rather than
# asserted from the code path: bin/fm-spawn.sh launches an agent into a REAL tmux
# pane on a private socket, the agent is KILLED with a real signal, and
# bin/fm-crew-state.sh is then asked what happened. A guard nobody has watched
# fire is not verified, so nothing here stubs the capture - the record is written
# by the pane's own shell exactly as it is in production, and the assertions read
# whatever that shell actually wrote.
#
# Two properties are load-bearing and are asserted separately:
#   - the record is ARMED but not completed while the agent is still running, so
#     "still working" and "died and told us" are distinguishable;
#   - a killed agent yields the SIGNAL, not just "endpoint unknown".
#
# The scenario runs once per pane shell firstmate actually meets (bash and, when
# installed, zsh), because the capture rides the launch line and is therefore the
# pane shell's `$?`, not firstmate's.
#
# It needs no harness and no credentials: the stand-in agent is a symlink to a
# real long-running system binary, the same technique tests/fm-tmux-agent-liveness
# .test.sh uses (a COPY of a platform binary fails code-signing on macOS arm64).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v pgrep >/dev/null 2>&1 || { echo "skip: pgrep not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }
BASH_BIN=$(command -v bash) || { echo "skip: bash not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-exit-capture-$$"
TMP_ROOT=$(fm_test_tmproot fm-exit-capture)
fm_git_identity fmtest fmtest@example.invalid

kill_tmux_server() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
}
trap 'kill_tmux_server; fm_test_cleanup' EXIT

# A `tmux` shim so every bare `tmux` call from bin/ reaches the private socket
# and can never touch the captain's real sessions.
SHIM="$TMP_ROOT/shim"
mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"

# The stand-in agent: a long-running process with its own executable identity.
AGENT_BIN="$TMP_ROOT/bin"
mkdir -p "$AGENT_BIN"
ln -s "$SLEEP_BIN" "$AGENT_BIN/fmagent"
cat > "$AGENT_BIN/fmquit" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$AGENT_BIN/fmquit"

poll() {  # <seconds> <command...> - 0 as soon as the command succeeds
  local deadline=$1; shift
  local i=0 max=$((deadline * 10))
  while [ "$i" -lt "$max" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

record_field() {  # <state-dir> <id> <key>
  grep "^$3=" "$1/$2.exit" 2>/dev/null | tail -1 | cut -d= -f2-
}
record_has_exit() {  # <state-dir> <id>
  [ -n "$(record_field "$1" "$2" exit_status)" ]
}

# One complete home + project + worktree, and a fake `treehouse` that moves the
# pane into that worktree the way the real one does (by exec'ing a shell there),
# so fm-spawn's own worktree-detection poll settles exactly as in production.
# <pane-shell> is the shell that ends up reading the launch line.
make_case() {  # <name> <pane-shell> -> echoes "<home>|<project>|<fakebin>"
  local name=$1 pane_shell=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin="$case_dir/fakebin"
  mkdir -p "$home/data" "$home/state" "$home/projects" "$home/config" "$fakebin"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
cd "$wt" || exit 1
exec "$pane_shell"
SH
  chmod +x "$fakebin/treehouse"
  # fm-crew-state.sh consults no-mistakes for a matching run; this throwaway
  # branch has none, and a silent fake keeps the read hermetic and fast.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s|%s|%s\n' "$home" "$proj" "$fakebin"
}

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  printf 'Delivery contract: mode=no-mistakes\nStand-in brief for %s.\n' "$2" > "$1/data/$2/brief.md"
}

spawn_agent() {  # <home> <project> <fakebin> <id> <launch command>
  PATH="$3:$SHIM:$PATH" \
  FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
  FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
  FM_HOME="$1" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$4" "$2" "$5" --mode no-mistakes --yolo off 2>&1
}

crew_state() {  # <home> <fakebin> <id>
  PATH="$2:$SHIM:$PATH" \
  FM_ROOT_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    "$ROOT/bin/fm-crew-state.sh" "$3"
}

# The whole point: spawn a real agent, kill it with a real signal, and read the
# signal back out of firstmate.
test_killed_agent_reports_its_signal() {  # <pane-shell-name> <pane-shell-path>
  local shell_name=$1 pane_shell=$2 id="killed-$1"
  local home proj fakebin out pid state
  IFS='|' read -r home proj fakebin <<< "$(make_case "$id" "$pane_shell")"
  write_brief "$home" "$id"
  out=$(spawn_agent "$home" "$proj" "$fakebin" "$id" "$AGENT_BIN/fmagent 900") \
    || fail "$shell_name: spawn failed: $out"

  # Armed, and deliberately NOT yet recorded: a running agent must be
  # distinguishable from one that died without saying so.
  poll 30 test -f "$home/state/$id.exit" || fail "$shell_name: exit record was never armed"
  poll 30 pgrep -f "$AGENT_BIN/fmagent 900" || fail "$shell_name: the agent never started"
  record_has_exit "$home/state" "$id" \
    && fail "$shell_name: a still-running agent must not carry a recorded exit"
  [ "$("$ROOT/bin/fm-exit-record.sh" show "$home/state" "$id" | cut -f1)" = armed ] \
    || fail "$shell_name: a running agent's record should read armed"

  pid=$(pgrep -f "$AGENT_BIN/fmagent 900" | head -1)
  [ -n "$pid" ] || fail "$shell_name: could not resolve the agent pid"
  kill -9 "$pid" || fail "$shell_name: kill -9 failed"

  poll 30 record_has_exit "$home/state" "$id" \
    || fail "$shell_name: the pane shell never recorded the agent's exit"
  [ "$(record_field "$home/state" "$id" exit_status)" = 137 ] \
    || fail "$shell_name: expected exit_status 137, got $(record_field "$home/state" "$id" exit_status)"
  [ "$(record_field "$home/state" "$id" exit_signal)" = 9 ] \
    || fail "$shell_name: expected signal 9, got $(record_field "$home/state" "$id" exit_signal)"
  [ "$(record_field "$home/state" "$id" exit_disposition)" = abnormal ] \
    || fail "$shell_name: a killed agent must record an abnormal disposition"

  # And the part that reaches firstmate: the same kill, read back through the
  # helper the supervision protocol actually calls on a stale wake.
  state=$(crew_state "$home" "$fakebin" "$id")
  case "$state" in
    *"state: failed"*) ;;
    *) fail "$shell_name: crew state should report failed, got: $state" ;;
  esac
  case "$state" in
    *"source: exit-record"*) ;;
    *) fail "$shell_name: crew state should name the exit record, got: $state" ;;
  esac
  case "$state" in
    *"signal 9"*) ;;
    *) fail "$shell_name: crew state should name the signal, got: $state" ;;
  esac
  case "$state" in
    *"source: none"*) fail "$shell_name: the pre-fix unexplained verdict came back: $state" ;;
  esac
  pass "$shell_name pane: a killed agent is reported as failed on signal 9, not unknown"
}

# The opposite direction: an agent that returns 0 must not be dressed up as a
# failure, and must not be promoted to done either.
test_clean_agent_exit_is_recorded_as_clean() {
  local id=clean-exit home proj fakebin out state
  IFS='|' read -r home proj fakebin <<< "$(make_case "$id" "$BASH_BIN")"
  write_brief "$home" "$id"
  out=$(spawn_agent "$home" "$proj" "$fakebin" "$id" "$AGENT_BIN/fmquit --now") \
    || fail "spawn failed: $out"
  poll 30 record_has_exit "$home/state" "$id" \
    || fail "a cleanly exiting agent was never recorded"
  [ "$(record_field "$home/state" "$id" exit_status)" = 0 ] \
    || fail "expected exit_status 0, got $(record_field "$home/state" "$id" exit_status)"
  [ "$(record_field "$home/state" "$id" exit_disposition)" = clean ] \
    || fail "a zero exit must record a clean disposition"
  state=$(crew_state "$home" "$fakebin" "$id")
  case "$state" in
    *"state: failed"*) fail "a clean exit must not be reported as a failure: $state" ;;
    *"state: done"*) fail "a clean process exit must not be promoted to done: $state" ;;
  esac
  case "$state" in
    *"agent exited cleanly"*) ;;
    *) fail "the clean exit should still be visible as detail, got: $state" ;;
  esac
  pass "an agent that returns 0 is recorded clean and is neither a failure nor a done"
}

test_killed_agent_reports_its_signal bash "$BASH_BIN"
if ZSH_BIN=$(command -v zsh 2>/dev/null); then
  test_killed_agent_reports_its_signal zsh "$ZSH_BIN"
else
  echo "note: zsh not installed; the zsh pane-shell pass did not run"
fi
test_clean_agent_exit_is_recorded_as_clean

echo "all fm-exit-capture e2e tests passed"
