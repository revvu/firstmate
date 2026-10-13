#!/usr/bin/env bash
# Contract: docs/examples/crew-dispatch.fleet.json is a real input, not an
# illustration. docs/routing-policy.md tells the captain to copy it into each
# home's config/crew-dispatch.json, so a policy edit that lands a malformed
# profile, an unverified harness, or an effort a harness rejects would surface
# only as a CREW_DISPATCH complaint on somebody's next session start.
#
# So drive the shipped file through its real consumer, bin/fm-bootstrap.sh's
# crew-dispatch validation and rule rendering, and assert the routing the
# captain set from the rendered profile sets rather than from the rules'
# prose: Cursor leads chores and fan-out, Codex leads frontier implementation
# and review, Fable leads design with high-effort Opus behind it, and Opus is
# the standing default. The validator's own behavior on malformed configs
# stays owned by tests/fm-bootstrap.test.sh; this file owns the shipped file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXAMPLE="$ROOT/docs/examples/crew-dispatch.fleet.json"
TMP_ROOT=$(fm_test_tmproot fm-crew-dispatch-fleet)

command -v jq >/dev/null 2>&1 || fail "jq is required to validate a dispatch profile"

# The dispatch lines bin/fm-bootstrap.sh prints for a home whose
# config/crew-dispatch.json is the given file: read-only detect phase with the
# network half skipped, so the fixture home is only read, and every other
# diagnostic this machine happens to emit is filtered out.
dispatch_lines() {
  local config=$1 home
  home="$TMP_ROOT/home"
  rm -rf "$home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  cp "$config" "$home/config/crew-dispatch.json"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_VERBOSE_FACTS=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null |
    grep -E '^(CREW_DISPATCH|BOOTSTRAP_INFO: crew dispatch)' || true
}

# The leading words of each rule's `when`, in file order, joined to its
# rendered profile set: the routing matrix as bootstrap sees it.
rendered_matrix() {
  dispatch_lines "$EXAMPLE" | awk '
    /^BOOTSTRAP_INFO: crew dispatch rule: The task is / {
      head = $0
      sub(/^BOOTSTRAP_INFO: crew dispatch rule: The task is /, "", head)
      sub(/:.*$/, "", head)
      print head " -> " substr($0, index($0, " -> ") + 4)
      next
    }
    /^BOOTSTRAP_INFO: crew dispatch default: / {
      sub(/^BOOTSTRAP_INFO: crew dispatch default: /, "")
      print "default -> " $0
    }'
}

test_fleet_matrix_activates_as_a_valid_dispatch_profile() {
  local out
  out=$(dispatch_lines "$EXAMPLE")
  assert_not_contains "$out" "CREW_DISPATCH: invalid" "the fleet matrix is not activatable"
  assert_contains "$out" "BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json" \
    "bootstrap did not report the fleet matrix as an active dispatch profile"
  pass "the fleet routing matrix activates cleanly through bootstrap's validator"
}

test_fleet_matrix_routes_each_class_as_the_captain_set() {
  local out expect
  out=$(rendered_matrix)
  # Codex profiles name no model, so bootstrap renders them as codex/default/<effort>.
  expect=$'design, architecture, or a clarifying question -> quota-balanced[claude/claude-fable-5-1/high, claude/opus/high]\nfan-out work -> quota-balanced[cursor, codex/default/medium]\na chore -> quota-balanced[cursor, codex/default/low]\nfrontier implementation -> quota-balanced[codex/default/high, claude/opus/high]\nan ordinary ship -> cursor\ncode review -> quota-balanced[codex/default/high, claude/opus/high]\ndefault -> claude/opus'
  [ "$out" = "$expect" ] || fail "fleet routing matrix drifted"$'\n'"expected:"$'\n'"$expect"$'\n'"actual:"$'\n'"$out"
  pass "Cursor leads chores and fan-out, Codex leads implementation and review, Fable then Opus leads design, Opus is the default"
}

test_fleet_matrix_pins_a_model_on_every_claude_profile() {
  local out unpinned
  out=$(dispatch_lines "$EXAMPLE")
  assert_not_contains "$out" "claude/default" \
    "a Claude profile resolved to the machine's ambient model instead of a pinned one"
  # The check has teeth: drop one profile's model and the same consumer
  # renders the ambient-model form the assertion above rejects.
  unpinned="$TMP_ROOT/unpinned.json"
  jq 'del(.rules[0].use[1].model)' "$EXAMPLE" > "$unpinned" || fail "could not build the unpinned control config"
  out=$(dispatch_lines "$unpinned")
  assert_contains "$out" "claude/default" "dropping a pinned model did not surface as an ambient-model profile"
  pass "every Claude profile in the fleet matrix pins its model explicitly"
}

test_validator_rejects_a_broken_edit_of_the_matrix() {
  local out broken
  broken="$TMP_ROOT/broken.json"
  jq '.rules[1].use[0].effort = "high"' "$EXAMPLE" > "$broken" || fail "could not build the broken control config"
  out=$(dispatch_lines "$broken")
  assert_contains "$out" "CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: cursor:high" \
    "an effort on the Cursor profile, which has no effort flag, should be refused"
  jq '.default.harness = "spaceship"' "$EXAMPLE" > "$broken" || fail "could not build the broken control config"
  out=$(dispatch_lines "$broken")
  assert_contains "$out" "CREW_DISPATCH: invalid config/crew-dispatch.json - unverified harness: spaceship" \
    "an unverified default harness should be refused"
  pass "the validator refuses a Cursor effort and an unverified harness edited into the matrix"
}

test_fleet_matrix_activates_as_a_valid_dispatch_profile
test_fleet_matrix_routes_each_class_as_the_captain_set
test_fleet_matrix_pins_a_model_on_every_claude_profile
test_validator_rejects_a_broken_edit_of_the_matrix

echo "# all fm-crew-dispatch-fleet tests passed"
