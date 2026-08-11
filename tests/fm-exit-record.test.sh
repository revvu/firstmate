#!/usr/bin/env bash
# Behavior tests for bin/fm-exit-record.sh - the agent-process exit record.
#
# The guarantee under test is asymmetric on purpose: a recorded abnormal exit
# must be reported precisely (status, derived signal, and the fact that the
# signal is DERIVED), while absence of a record must never be readable as
# success. Inferring "it finished fine" from missing evidence is the exact
# failure mode the record exists to remove, so every not-recorded shape - never
# armed, armed but never completed, and a corrupted file - is asserted to stay
# unknown rather than clean.
#
# The record is also asserted to survive its own writer: `record` preserves the
# armed half (the spawn-time host snapshot) so the two snapshots can be compared
# afterwards, which is the whole point of capturing one at spawn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXITREC="$ROOT/bin/fm-exit-record.sh"
TMP_ROOT=$(fm_test_tmproot fm-exit-record)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

# Disposition token from `show` (field 1), and the summary (field 2).
show_disposition() {  # <id>
  "$EXITREC" show "$STATE" "$1" | cut -f1
}
show_detail() {  # <id>
  "$EXITREC" show "$STATE" "$1" | cut -f2-
}
record_field() {  # <id> <key>
  grep "^$2=" "$STATE/$1.exit" | tail -1 | cut -d= -f2-
}

# Every snapshot field is always present and never blank: a platform that cannot
# supply a figure must say `unknown`, so a reader can never confuse "not
# measured" with "measured zero".
assert_snapshot_complete() {  # <id> <prefix> <label>
  local id=$1 prefix=$2 label=$3 f v
  for f in mem_free_mb mem_total_mb mem_compressed_mb swap_used_mb swap_total_mb load1; do
    v=$(record_field "$id" "${prefix}_$f")
    [ -n "$v" ] || fail "$label: ${prefix}_$f is missing or blank"
  done
}

test_absent_record_is_not_a_clean_exit() {
  local out
  out=$("$EXITREC" show "$STATE" never-armed)
  [ "$(printf '%s' "$out" | cut -f1)" = none ] \
    || fail "an absent record must read 'none', got: $out"
  printf '%s' "$out" | grep -qi 'clean' \
    && fail "an absent record must never mention a clean exit"
  pass "an absent record reads none, never a clean exit"
}

test_armed_record_reports_not_recorded() {
  "$EXITREC" arm "$STATE" armed-only || fail "arm failed"
  [ "$(show_disposition armed-only)" = armed ] \
    || fail "an armed record must read 'armed', got: $(show_disposition armed-only)"
  show_detail armed-only | grep -Fq 'agent exit not recorded' \
    || fail "the armed summary must say the exit was not recorded: $(show_detail armed-only)"
  assert_snapshot_complete armed-only armed "armed record"
  pass "an armed-but-never-completed record reads as exit-not-recorded"
}

test_clean_exit_is_reported_as_clean() {
  "$EXITREC" arm "$STATE" clean-exit || fail "arm failed"
  "$EXITREC" record "$STATE" clean-exit 0 || fail "record failed"
  [ "$(show_disposition clean-exit)" = recorded-clean ] \
    || fail "status 0 must read recorded-clean, got: $(show_disposition clean-exit)"
  [ "$(record_field clean-exit exit_disposition)" = clean ] || fail "exit_disposition should be clean"
  [ "$(record_field clean-exit exit_signal)" = none ] || fail "a clean exit carries no signal"
  [ "$(record_field clean-exit exit_signal_basis)" = none ] || fail "a clean exit carries no signal basis"
  pass "an exit status of 0 is recorded as a clean exit with no signal"
}

# The load-bearing case: a signal-killed agent. The record must name the signal
# AND name the inference it comes from, because a shell reports 128+N and cannot
# distinguish that from a program that deliberately exited 128+N.
test_signalled_exit_names_signal_and_its_basis() {
  local label status signal name
  while IFS='|' read -r label status signal name; do
    [ -n "$label" ] || continue
    "$EXITREC" arm "$STATE" "sig-$status" || fail "$label: arm failed"
    "$EXITREC" record "$STATE" "sig-$status" "$status" || fail "$label: record failed"
    [ "$(show_disposition "sig-$status")" = recorded-abnormal ] \
      || fail "$label: must read recorded-abnormal"
    [ "$(record_field "sig-$status" exit_signal)" = "$signal" ] \
      || fail "$label: expected signal $signal, got $(record_field "sig-$status" exit_signal)"
    [ "$(record_field "sig-$status" exit_signal_name)" = "$name" ] \
      || fail "$label: expected signal name $name, got $(record_field "sig-$status" exit_signal_name)"
    [ "$(record_field "sig-$status" exit_signal_basis)" = exit-status-convention ] \
      || fail "$label: the record must name the derivation basis"
    show_detail "sig-$status" | grep -Fq "signal $signal" \
      || fail "$label: the summary must name the signal: $(show_detail "sig-$status")"
    show_detail "sig-$status" | grep -Fq "status $status" \
      || fail "$label: the summary must keep the raw status: $(show_detail "sig-$status")"
    assert_snapshot_complete "sig-$status" exit "$label"
  done <<'ROWS'
SIGKILL|137|9|KILL
SIGTERM|143|15|TERM
SIGHUP|129|1|HUP
ROWS
  pass "a signalled exit records the signal, its name, and the derivation it came from"
}

# A nonzero exit that is NOT in the signal range must not be dressed up as one.
test_plain_failure_is_abnormal_without_a_signal() {
  local label status
  while IFS='|' read -r label status; do
    [ -n "$label" ] || continue
    "$EXITREC" arm "$STATE" "plain-$status" || fail "$label: arm failed"
    "$EXITREC" record "$STATE" "plain-$status" "$status" || fail "$label: record failed"
    [ "$(show_disposition "plain-$status")" = recorded-abnormal ] \
      || fail "$label: a nonzero exit must read recorded-abnormal"
    [ "$(record_field "plain-$status" exit_signal)" = none ] \
      || fail "$label: status $status must not be attributed to a signal"
    show_detail "plain-$status" | grep -Fq "status $status" \
      || fail "$label: the summary must carry the raw status"
    show_detail "plain-$status" | grep -Fq 'signal' \
      && fail "$label: the summary must not mention a signal"
  done <<'ROWS'
ordinary failure|1
command not found|127
exactly 128 is not signal 0|128
above the signal range|200
ROWS
  pass "a nonzero non-signal exit is abnormal and claims no signal"
}

# The armed half carries the spawn-time host snapshot the exit-time snapshot is
# meant to be compared against, so completing the record must not discard it.
test_record_preserves_the_armed_half() {
  "$EXITREC" arm "$STATE" preserve || fail "arm failed"
  local armed_at
  armed_at=$(record_field preserve armed_at)
  [ -n "$armed_at" ] || fail "armed_at missing after arm"
  "$EXITREC" record "$STATE" preserve 137 || fail "record failed"
  [ "$(record_field preserve armed_at)" = "$armed_at" ] \
    || fail "record must preserve armed_at verbatim"
  assert_snapshot_complete preserve armed "preserved armed half"
  assert_snapshot_complete preserve exit "exit half"
  pass "completing the record preserves the spawn-time snapshot it is compared against"
}

# A record written by a spawn that predates exit capture (or whose armed half was
# removed) still records the exit rather than dropping the one fact available.
test_record_without_an_armed_half_still_records() {
  "$EXITREC" record "$STATE" no-arm 137 || fail "record without arm failed"
  [ "$(show_disposition no-arm)" = recorded-abnormal ] \
    || fail "an unarmed record must still report the exit"
  [ "$(record_field no-arm armed_at)" = unknown ] \
    || fail "a missing armed half must read unknown, not be invented"
  pass "an exit is recorded even when the armed half is absent"
}

# Corruption must degrade to unknown, never to success.
test_corrupt_records_read_unreadable() {
  printf 'v=99\nid=bad-version\nexit_status=0\nexit_disposition=clean\n' > "$STATE/bad-version.exit"
  [ "$(show_disposition bad-version)" = unreadable ] \
    || fail "an unknown format version must read unreadable, got: $(show_disposition bad-version)"
  printf 'v=1\nid=bad-status\nexit_status=notanumber\n' > "$STATE/bad-status.exit"
  [ "$(show_disposition bad-status)" = unreadable ] \
    || fail "a non-numeric exit status must read unreadable"
  printf 'v=1\nid=bad-clean\nexit_status=1\nexit_disposition=clean\n' > "$STATE/bad-clean.exit"
  [ "$(show_disposition bad-clean)" = unreadable ] \
    || fail "a clean disposition on a nonzero status must read unreadable"
  printf 'v=1\nid=missing-disposition\nexit_status=0\n' > "$STATE/missing-disposition.exit"
  [ "$(show_disposition missing-disposition)" = unreadable ] \
    || fail "a recorded status without its disposition must read unreadable"
  : > "$STATE/empty.exit"
  [ "$(show_disposition empty)" = unreadable ] \
    || fail "an empty record must read unreadable"
  local id
  for id in bad-version bad-status bad-clean missing-disposition empty; do
    show_detail "$id" | grep -qi 'clean' && fail "$id: a corrupt record must never read as clean"
  done
  pass "corrupt records read unreadable and never as a clean exit"
}

test_usage_errors_exit_2() {
  local status
  "$EXITREC" >/dev/null 2>&1
  status=$?
  [ "$status" -eq 2 ] || fail "no subcommand should exit 2, got $status"
  "$EXITREC" record "$STATE" >/dev/null 2>&1
  status=$?
  [ "$status" -eq 2 ] || fail "record with missing arguments should exit 2, got $status"
  "$EXITREC" arm "$TMP_ROOT/no-such-state-dir" x >/dev/null 2>&1
  status=$?
  [ "$status" -eq 2 ] || fail "arm into a missing state dir should exit 2, got $status"
  "$EXITREC" --help >/dev/null 2>&1
  status=$?
  [ "$status" -eq 0 ] || fail "--help should exit 0, got $status"
  pass "usage errors exit 2 and --help exits 0"
}

test_absent_record_is_not_a_clean_exit
test_armed_record_reports_not_recorded
test_clean_exit_is_reported_as_clean
test_signalled_exit_names_signal_and_its_basis
test_plain_failure_is_abnormal_without_a_signal
test_record_preserves_the_armed_half
test_record_without_an_armed_half_still_records
test_corrupt_records_read_unreadable
test_usage_errors_exit_2
