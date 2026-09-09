#!/usr/bin/env bash
# Contract: docs/examples/crew-dispatch.json is a real input, not an illustration.
# docs/routing-policy.md step 3 tells the captain to copy it into each home's
# config/crew-dispatch.json, and a seeded home starts from the same file, so a
# policy edit that lands a malformed profile or an unverified harness would
# surface only as a CREW_DISPATCH complaint on somebody's next session start.
#
# So drive the shipped file through its real consumer - bin/fm-bootstrap.sh's
# crew-dispatch validation and rule rendering - and assert the model axis the
# captain pinned on 2026-09-09 from the normalized profile set rather than from
# the rules' prose: every Claude profile names its model instead of inheriting
# the machine's ambient default, the only Claude models are Opus and Fable, and
# Fable appears in exactly two classes, each keeping a strong-reasoning Claude
# fallback rather than falling to a speed-class harness.
#
# The validator's own behavior on malformed configs stays owned by
# tests/fm-bootstrap.test.sh; this file owns only the shipped artifact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXAMPLE="$ROOT/docs/examples/crew-dispatch.json"
TMP_ROOT=$(fm_test_tmproot fm-crew-dispatch-example)

command -v jq >/dev/null 2>&1 || fail "jq is required to validate a dispatch profile"

# The dispatch lines bin/fm-bootstrap.sh prints for a home whose
# config/crew-dispatch.json is the given file. Read-only detect phase with the
# network half skipped, so the fixture home is only read; every other
# diagnostic this machine happens to emit is irrelevant here and filtered out.
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

test_shipped_example_activates_as_a_valid_dispatch_profile() {
  local out
  out=$(dispatch_lines "$EXAMPLE")
  assert_not_contains "$out" "CREW_DISPATCH: invalid" \
    "the shipped example dispatch config is not activatable"
  assert_contains "$out" "BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json" \
    "bootstrap did not report the shipped example as an active dispatch profile"
  pass "the shipped crew-dispatch example activates cleanly through bootstrap's validator"
}

test_shipped_example_pins_a_model_on_every_claude_profile() {
  local out unpinned
  out=$(dispatch_lines "$EXAMPLE")
  assert_not_contains "$out" "claude/default" \
    "a Claude profile resolved to the machine's ambient model instead of a pinned one"

  # And the check has teeth: drop one profile's model and the same consumer
  # renders the ambient-model form the assertion above rejects.
  unpinned="$TMP_ROOT/unpinned.json"
  jq 'del(.rules[0].use[1].model)' "$EXAMPLE" > "$unpinned" \
    || fail "could not build the unpinned control config"
  out=$(dispatch_lines "$unpinned")
  assert_contains "$out" "claude/default" \
    "dropping a pinned model did not surface as an ambient-model profile"
  pass "every Claude profile in the shipped example pins its model explicitly"
}

test_shipped_example_reserves_fable_and_keeps_a_strong_fallback() {
  local out facts expect
  out=$(dispatch_lines "$EXAMPLE")
  assert_contains "$out" "quota-balanced[claude/fable/xhigh, claude/opus/xhigh]" \
    "the substantial-design class did not resolve to Fable then Opus at xhigh"
  assert_contains "$out" "quota-balanced[claude/fable/high, claude/opus/high]" \
    "the visual-convergence class did not resolve to Fable then Opus at high"

  facts=$(jq -r '
    def profiles: if type == "array" then .[] else . end;
    def all_profiles: [(.rules[].use | profiles), (.default | profiles)];
    def plabel: .harness
      + (if has("model") then "/" + .model else "" end)
      + (if has("effort") then "/" + .effort else "" end);
    [ "claude_models=" + ([all_profiles[] | select(.harness == "claude") | .model] | unique | join(",")),
      "fable_classes=" + ([.rules[]
        | select([.use | profiles | select(.harness == "claude" and .model == "fable")] | length > 0)
        | [.use | profiles | plabel] | join(" then ")] | join(" | ")),
      "default=" + ([.default | profiles | plabel] | join(" then "))
    ] | .[]
  ' "$EXAMPLE") || fail "could not normalize the shipped example dispatch profiles"

  expect=$'claude_models=fable,opus\nfable_classes=claude/fable/xhigh then claude/opus/xhigh | claude/fable/high then claude/opus/high\ndefault=cursor then codex/medium then claude/opus/medium'
  [ "$facts" = "$expect" ] || fail "shipped example Claude model routing drifted"$'\n'"expected: $expect"$'\n'"actual:   $facts"
  pass "Fable is reserved to two classes, each falling back to Opus rather than a speed-class harness"
}

test_shipped_example_activates_as_a_valid_dispatch_profile
test_shipped_example_pins_a_model_on_every_claude_profile
test_shipped_example_reserves_fable_and_keeps_a_strong_fallback
