#!/usr/bin/env bash
# Behavior tests for the `cswap` form of the Claude worker account pin
# (config/claude-account = cswap; bin/fm-cswap-pick.sh through
# bin/fm-worker-account-lib.sh).
#
# Each case drives the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, then runs that command in a synthetic pane whose
# ambient environment carries another account. A fake cswap answers
# `list --json` from a per-case fixture and records every `run`, seeding the
# session profile the way the real tool does; the fake claude answers the
# sign-in check from the selected root's stored login, as in
# tests/fm-worker-account.test.sh, which owns the literal-path and ordinary
# forms this suite does not repeat.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-cswap-account)
unset LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN XDG_DATA_HOME
command -v jq >/dev/null 2>&1 || fail "jq is required: bin/fm-cswap-pick.sh reads cswap list --json with it"

# cswap's backup root for the throwaway spawn HOME, the rule
# bin/fm-cswap-pick.sh follows from claude_swap/paths.py.
sessions_dir() {
  case "$(uname -s)" in
    Linux) printf '%s\n' "$1/.local/share/claude-swap/sessions" ;;
    *) printf '%s\n' "$1/.claude-swap-backup/sessions" ;;
  esac
}

# make_fakes <fakebin> <case-dir> <sessions-dir>
make_fakes() {
  local fakebin=$1 dir=$2 sessions=$3
  cat > "$fakebin/claude" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> '$dir/claude-checks'
  [ -f "\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/.credentials.json" ]
  exit
fi
{
  printf 'CLAUDE_CONFIG_DIR=%s\n' "\${CLAUDE_CONFIG_DIR-unset}"
  printf 'ANTHROPIC_API_KEY=%s\n' "\${ANTHROPIC_API_KEY-unset}"
  printf 'ARGS=%s\n' "\$*"
} > '$dir/claude-worker'
SH
  cat > "$fakebin/cswap" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "list --json") cat '$dir/cswap-list.json'; exit 0 ;;
  "run "*)
    printf '%s\n' "\$*" >> '$dir/cswap-runs'
    [ "\${3:-}" = --require-session ] || exit 1
    email=\$(jq -r --argjson n "\$2" '.accounts[] | select(.number == \$n) | .email' '$dir/cswap-list.json')
    [ -n "\$email" ] || exit 1
    slug=\$(printf '%s' "\$email" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g')
    mkdir -p '$sessions'/"\$2-\$slug"
    printf '{}\n' > '$sessions'/"\$2-\$slug/.credentials.json"
    exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/claude" "$fakebin/cswap"
}

# account <number> <email> <active> <fiveHour> <sevenDay> [<fable-pct>|-] [disabled|<usageStatus>]
account() {
  local n=$1 email=$2 active=$3 five=$4 seven=$5 fable=${6:--} flag=${7:-}
  jq -nc --argjson n "$n" --arg email "$email" --argjson active "$active" \
    --argjson five "$five" --argjson seven "$seven" --arg fable "$fable" --arg flag "$flag" '
    {number: $n, email: $email, active: $active, usageStatus: (if $flag == "" or $flag == "disabled" then "ok" else $flag end),
     usage: {fiveHour: {pct: $five}, sevenDay: {pct: $seven},
             scoped: (if $fable == "-" then [] else [{name: "Fable", pct: ($fable | tonumber)}] end)}}
    + (if $flag == "disabled" then {disabled: true} else {} end)'
}

# listing <case-dir> <account-json>...
listing() {
  local dir=$1
  shift
  printf '%s\n' "$@" | jq -s '{schemaVersion: 1, accounts: .}' > "$dir/cswap-list.json"
}

# new_case <name> -> sets CASE HOME_DIR PROJ WT FAKEBIN SESSIONS
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  WT="$CASE/wt"
  SESSIONS=$(sessions_dir "$HOME_DIR/user-home")
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  make_fakes "$FAKEBIN" "$CASE" "$SESSIONS"
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  mkdir -p "$HOME_DIR/user-home"
  printf 'cswap\n' > "$HOME_DIR/config/claude-account"
  : > "$CASE/launch.log"
}

# spawn_ship <id> [fm-spawn args...]: a ship spawn whose invoking process
# carries an ambient Claude root and API key that the pin must not keep.
spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  mkdir -p "$CASE/ambient-claude"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" FM_TEST_CLAUDE_CONFIG_DIR="$CASE/ambient-claude" \
    ANTHROPIC_API_KEY=ambient-invoker-key \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off "$@"
}

run_pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm \
    CLAUDE_CONFIG_DIR="$CASE/ambient-claude" ANTHROPIC_API_KEY=ambient-pane-key \
    bash -c "$(cat "$CASE/launch.log")" || fail "the recorded launch failed in the synthetic pane"
}

assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_cswap_pin_launches_on_the_account_with_the_most_remaining_quota() {
  local out rc id=cswap-best root
  new_case best
  # Account 1 (active) has 40% left, account 2 has 80%, account 3 would win
  # outright but is held out of rotation.
  listing "$CASE" \
    "$(account 1 captain@example.com true 10 60)" \
    "$(account 2 'worker two@example.com' false 5 20)" \
    "$(account 3 spare@example.com false 0 0 - disabled)"
  root="$SESSIONS/2-worker_two_example.com"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "a cswap pin with a usable account should launch: $out"
  assert_contains "$out" "account=cswap:2" "the spawn should report the picked account"
  assert_grep "account=cswap:2" "$HOME_DIR/state/$id.meta" "the task record should carry the picked account"
  [ "$(cat "$CASE/cswap-runs")" = "run 2 --require-session -- --version" ] \
    || fail "the missing session profile should be prepared through cswap run exactly once: $(cat "$CASE/cswap-runs")"
  [ "$(cat "$CASE/claude-checks")" = "$root" ] \
    || fail "the sign-in check should ask about the picked session profile only: $(cat "$CASE/claude-checks")"
  assert_contains "$(cat "$HOME_DIR/user-home/.claude.json" 2>/dev/null; cat "$root/.claude.json" 2>/dev/null)" "$WT" \
    "workspace trust should be registered for the launch"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$root" "$CASE/claude-worker" "the worker should run under the picked session profile"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the picked account"

  out=$(spawn_ship "$id-again"); rc=$?
  expect_code 0 "$rc" "a second spawn should reuse the prepared profile: $out"
  [ "$(wc -l < "$CASE/cswap-runs" | tr -d ' ')" = 1 ] \
    || fail "an existing session profile must not be prepared again: $(cat "$CASE/cswap-runs")"
  pass "a cswap pin launches on the account with the most remaining quota in its own session profile"
}

test_cswap_pin_keeps_the_active_login_when_it_has_the_most_left() {
  local out rc id=cswap-active
  new_case active
  listing "$CASE" \
    "$(account 1 captain@example.com true 1 15)" \
    "$(account 2 worker@example.com false 0 30)"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "the active login with no stored default login must refuse"
  assert_refused_before_launch "$id" "$out" "pins Claude workers to the ordinary account, which is not signed in"
  mkdir -p "$HOME_DIR/user-home/.claude"
  printf '{}\n' > "$HOME_DIR/user-home/.claude/.credentials.json"
  : > "$CASE/claude-checks"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 0 "$rc" "the active login with a stored default login should launch: $out"
  assert_contains "$out" "account=cswap:1" "the spawn should report the active account"
  assert_absent "$CASE/cswap-runs" "the active default login never gets a session profile"
  [ "$(cat "$CASE/claude-checks")" = unset ] \
    || fail "the active login check must run with CLAUDE_CONFIG_DIR unset: $(cat "$CASE/claude-checks")"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=unset" "$CASE/claude-worker" "the active login must drop the ambient Claude root"
  assert_grep "ANTHROPIC_API_KEY=unset" "$CASE/claude-worker" "an ambient API key must not outrank the active login"
  pass "a cswap pin whose best account is the active login runs on the default login without touching cswap"
}

test_cswap_pin_counts_the_fable_window_for_a_fable_model() {
  local out rc id=cswap-fable
  new_case fable
  # Account 1 leads on the account windows (85% left) but its Fable window
  # has 28% left; account 2 has 70% left everywhere it reports.
  listing "$CASE" \
    "$(account 1 captain@example.com true 1 15 72)" \
    "$(account 2 worker@example.com false 0 30)"
  mkdir -p "$HOME_DIR/user-home/.claude"
  printf '{}\n' > "$HOME_DIR/user-home/.claude/.credentials.json"
  out=$(spawn_ship "$id-opus" --model opus); rc=$?
  expect_code 0 "$rc" "an Opus spawn should launch: $out"
  assert_contains "$out" "account=cswap:1" "an Opus spawn should weigh only the account windows"
  out=$(spawn_ship "$id" --model claude-fable-5-1); rc=$?
  expect_code 0 "$rc" "a Fable spawn should launch: $out"
  assert_contains "$out" "account=cswap:2" "a Fable spawn should count the Fable window"
  run_pane
  assert_grep "CLAUDE_CONFIG_DIR=$SESSIONS/2-worker_example.com" "$CASE/claude-worker" \
    "the Fable worker should run under the account with the most Fable headroom"
  assert_grep "--model claude-fable-5-1" "$CASE/claude-worker" "the launch should keep the Fable model"
  pass "a Fable model picks by the Fable window, other models by the account windows"
}

test_cswap_pin_refuses_when_no_account_can_be_picked() {
  local out rc id=cswap-none
  new_case none
  listing "$CASE" \
    "$(account 1 captain@example.com true 1 15 - token_expired)" \
    "$(account 2 worker@example.com false 0 30 - unavailable)"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "a listing with no usable account must refuse"
  assert_refused_before_launch "$id" "$out" "config/claude-account selects cswap, but no claude-swap account could be picked (no usable claude-swap account"
  assert_absent "$CASE/claude-checks" "no sign-in check may run without a pick"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/cswap"
  out=$(spawn_ship "$id-broken"); rc=$?
  expect_code 1 "$rc" "a cswap pin whose cswap cannot list accounts must refuse"
  assert_refused_before_launch "$id-broken" "$out" "no claude-swap account could be picked (cswap list --json failed)"
  pass "a cswap pin refuses before launch when cswap cannot list accounts or lists no usable one"
}

test_cswap_pin_refuses_when_the_profile_cannot_be_prepared() {
  local out rc id=cswap-noprofile
  new_case noprofile
  listing "$CASE" \
    "$(account 1 captain@example.com true 50 50)" \
    "$(account 2 worker@example.com false 0 0)"
  cat > "$FAKEBIN/cswap" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "list --json") cat '$CASE/cswap-list.json'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$FAKEBIN/cswap"
  out=$(spawn_ship "$id"); rc=$?
  expect_code 1 "$rc" "a profile cswap cannot prepare must refuse"
  assert_refused_before_launch "$id" "$out" "cswap run 2 --require-session could not prepare the session profile for worker@example.com"
  pass "a cswap pin refuses before launch when the session profile cannot be prepared"
}

test_cswap_pin_launches_on_the_account_with_the_most_remaining_quota
test_cswap_pin_keeps_the_active_login_when_it_has_the_most_left
test_cswap_pin_counts_the_fable_window_for_a_fable_model
test_cswap_pin_refuses_when_no_account_can_be_picked
test_cswap_pin_refuses_when_the_profile_cannot_be_prepared

echo "# all fm-cswap-account tests passed"
