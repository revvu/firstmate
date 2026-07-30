#!/usr/bin/env bash
# tests/fm-linear-backend.test.sh - the Linear backlog backend: selection,
# authentication refusal, GraphQL transport errors, queue normalization and
# pagination, the CLI write verbs' request shapes, spawn --linear validation,
# and the bearings projection under config/backlog-backend=linear.
#
# The HTTP layer is a PATH-stubbed curl that records every request payload and
# answers from canned fixtures modeled on live captures; no test needs network
# access or a real LINEAR_API_KEY.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

CLI="$ROOT/bin/fm-backlog-linear.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-linear)

assert_eq() {  # <actual> <expected> <msg>
  [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"
}

# A fake curl that logs each request body to FM_FAKE_CURL_LOG and dispatches a
# canned response on the GraphQL operation inside the payload, then appends the
# HTTP status line exactly like the lib's `-w '\n%{http_code}'` template.
make_fake_curl() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
set -u
payload=$(cat)
printf '%s\n' "$payload" >> "$FM_FAKE_CURL_LOG"
printf '%s\n' "$*" >> "$(dirname "$FM_FAKE_CURL_LOG")/curl-args.log"
for arg in "$@"; do
  case "$arg" in
    *lin_api_test_fixture*) exit 90 ;;
    @*)
      header_file=${arg#@}
      if grep -Fx 'Authorization: lin_api_test_fixture' "$header_file" >/dev/null 2>&1; then
        mode=$(stat -f %Lp "$header_file" 2>/dev/null || stat -c %a "$header_file")
        [ "$mode" = 600 ] || exit 91
        printf 'auth-file-ok\n' >> "$(dirname "$FM_FAKE_CURL_LOG")/curl-auth.log"
      fi
      ;;
  esac
done
if [ "${FM_FAKE_CURL_STATUS:-200}" != 200 ]; then
  printf '%s\n%s' "${FM_FAKE_CURL_BODY:-{}}" "${FM_FAKE_CURL_STATUS}"
  exit 0
fi
if [ "${FM_FAKE_CURL_FORCE_ERRORS:-0}" = 1 ]; then
  printf '%s\n200' '{"errors":[{"message":"Something went wrong"}]}'
  exit 0
fi
case "$payload" in
  *'comments(first:'*)
    comments=${FM_FAKE_COMMENTS_JSON:-[]}
    body='{"data":{"issue":{"comments":{"nodes":'"$(printf '%s' "$comments" | jq -c 'map({body:.})')"',"pageInfo":{"hasNextPage":false,"endCursor":"COMMENTS-END"}}}}}'
    ;;
  *'viewer { id name email }'*)
    body='{"data":{"viewer":{"id":"u1","name":"reevu adakroy","email":"reevu.adakroy@gallopify.com"}}}'
    ;;
  *'issues(filter:'*)
    if [ "${FM_FAKE_CURL_PAGED:-0}" = 1 ]; then
      case "$payload" in
        *'"after":null'*)
          body='{"data":{"issues":{"nodes":[{"identifier":"PG-1","title":"Page one","url":"https://linear.app/x/issue/PG-1","updatedAt":"2026-07-01T00:00:00.000Z","completedAt":null,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[]}}],"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"}}}}'
          ;;
        *'"after":"CUR1"'*)
          body='{"data":{"issues":{"nodes":[{"identifier":"PG-2","title":"Page two","url":"https://linear.app/x/issue/PG-2","updatedAt":"2026-07-02T00:00:00.000Z","completedAt":null,"state":{"name":"Todo","type":"unstarted"},"assignee":null,"labels":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":"CUR2"}}}}'
          ;;
        *)
          body='{"errors":[{"message":"unexpected pagination cursor"}]}'
          ;;
      esac
    else
      body='{"data":{"issues":{"nodes":[
        {"identifier":"QB-1","title":"Backlog item","url":"https://linear.app/x/issue/QB-1","updatedAt":"2026-07-01T00:00:00.000Z","completedAt":null,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[]}},
        {"identifier":"QB-2","title":"Todo item","url":"https://linear.app/x/issue/QB-2","updatedAt":"2026-07-02T00:00:00.000Z","completedAt":null,"state":{"name":"Todo","type":"unstarted"},"assignee":{"name":"reevu adakroy"},"labels":{"nodes":[]}},
        {"identifier":"QB-3","title":"Triage item","url":"https://linear.app/x/issue/QB-3","updatedAt":"2026-07-03T00:00:00.000Z","completedAt":null,"state":{"name":"Triage","type":"triage"},"assignee":null,"labels":{"nodes":[]}},
        {"identifier":"QB-4","title":"Started item","url":"https://linear.app/x/issue/QB-4","updatedAt":"2026-07-04T00:00:00.000Z","completedAt":null,"state":{"name":"In Progress","type":"started"},"assignee":null,"labels":{"nodes":[]}},
        {"identifier":"QB-5","title":"Done item","url":"https://linear.app/x/issue/QB-5","updatedAt":"2026-07-05T00:00:00.000Z","completedAt":"2026-07-05T00:00:00.000Z","state":{"name":"Done","type":"completed"},"assignee":null,"labels":{"nodes":[]}},
        {"identifier":"QB-6","title":"Canceled item","url":"https://linear.app/x/issue/QB-6","updatedAt":"2026-07-06T00:00:00.000Z","completedAt":null,"state":{"name":"Canceled","type":"canceled"},"assignee":null,"labels":{"nodes":[]}},
        {"identifier":"QB-7","title":"Duplicate item","url":"https://linear.app/x/issue/QB-7","updatedAt":"2026-07-07T00:00:00.000Z","completedAt":null,"state":{"name":"Duplicate","type":"duplicate"},"assignee":null,"labels":{"nodes":[]}},
        {"identifier":"QB-8","title":"Mystery item","url":"https://linear.app/x/issue/QB-8","updatedAt":"2026-07-08T00:00:00.000Z","completedAt":null,"state":{"name":"Mystery","type":"mystery"},"assignee":null,"labels":{"nodes":[]}},
        {"identifier":"QB-9","title":"Held item","url":"https://linear.app/x/issue/QB-9","updatedAt":"2026-07-09T00:00:00.000Z","completedAt":null,"state":{"name":"Backlog","type":"backlog"},"assignee":null,"labels":{"nodes":[{"name":"captain-call"}]}}
      ],"pageInfo":{"hasNextPage":false,"endCursor":"END"}}}}'
    fi
    ;;
  *'issue(id: $id)'*)
    if [ "${FM_FAKE_ISSUE_LABELED:-0}" = 1 ]; then
      labels='{"nodes":[{"id":"label-1","name":"captain-call"}]}'
    else
      labels='{"nodes":[]}'
    fi
    body='{"data":{"issue":{"id":"uuid-1","identifier":"GAL-8","title":"Fixture issue","url":"https://linear.app/x/issue/GAL-8","description":"body","state":{"id":"state-backlog","name":"Backlog","type":"backlog"},"team":{"id":"team-1","key":"GAL"},"assignee":null,"labels":'"$labels"',"attachments":{"nodes":[]}}}}'
    ;;
  *'team(id: $id)'*)
    body='{"data":{"team":{"states":{"nodes":[
      {"id":"state-review","name":"In Review","type":"started","position":1002},
      {"id":"state-progress","name":"In Progress","type":"started","position":2},
      {"id":"state-done","name":"Done","type":"completed","position":3},
      {"id":"state-canceled","name":"Canceled","type":"canceled","position":4}
    ]}}}}'
    ;;
  *'issueLabels(filter:'*)
    body='{"data":{"issueLabels":{"nodes":[]}}}'
    ;;
  *'issueLabelCreate('*)
    body='{"data":{"issueLabelCreate":{"success":true,"issueLabel":{"id":"label-1"}}}}'
    ;;
  *'issueAddLabel('*)
    body='{"data":{"issueAddLabel":{"success":true}}}'
    ;;
  *'issueRemoveLabel('*)
    body='{"data":{"issueRemoveLabel":{"success":true}}}'
    ;;
  *'issueUpdate('*)
    body='{"data":{"issueUpdate":{"success":true}}}'
    ;;
  *'commentCreate('*)
    body='{"data":{"commentCreate":{"success":true}}}'
    ;;
  *'attachmentLinkURL('*)
    body='{"data":{"attachmentLinkURL":{"success":true}}}'
    ;;
  *'teams(first:'*)
    body='{"data":{"teams":{"nodes":[{"id":"team-1","key":"GAL","name":"Gallopify"}]}}}'
    ;;
  *)
    body='{"errors":[{"message":"unmatched fixture request"}]}'
    ;;
esac
printf '%s\n200' "$body"
SH
  chmod +x "$fb/curl"
  # The bearings test drives the real canonical snapshot, which probes recorded
  # endpoints; stub the session tools so no real terminal or pipeline is touched.
  fm_fake_exit0 "$fb" tmux no-mistakes gh gh-axi
  printf '%s\n' "$fb"
}

# One isolated home per test with the key present and the backend selected.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'linear\n' > "$home/config/backlog-backend"
  printf 'LINEAR_API_KEY=lin_api_test_fixture\n' > "$home/.env"
  printf '%s\n' "$home"
}

run_cli() {  # <home> <fakebin> <args...>
  local home=$1 fb=$2
  shift 2
  env -u LINEAR_API_KEY FM_HOME="$home" FM_FAKE_CURL_LOG="$home/curl.log" \
    PATH="$fb:$PATH" "$CLI" "$@"
}

# --- backend selection and identifier contract -------------------------------

test_backend_selection() {
  local home
  home=$(make_home selection)
  # shellcheck source=bin/fm-linear-lib.sh disable=SC1091
  . "$ROOT/bin/fm-linear-lib.sh"
  fm_linear_backend_selected "$home/config" || fail "linear value must select the backend"
  printf 'tasks-axi\n' > "$home/config/backlog-backend"
  fm_linear_backend_selected "$home/config" && fail "tasks-axi value must not select the backend"
  rm -f "$home/config/backlog-backend"
  fm_linear_backend_selected "$home/config" && fail "absent config must not select the backend"
  pass "backend selection follows config/backlog-backend"
}

test_identifier_validation() {
  # shellcheck source=bin/fm-linear-lib.sh disable=SC1091
  . "$ROOT/bin/fm-linear-lib.sh"
  fm_linear_identifier_valid GAL-8 || fail "GAL-8 must be a valid identifier"
  fm_linear_identifier_valid BUILD-19 || fail "BUILD-19 must be a valid identifier"
  for bad in "bad id" "GAL-" "-8" "GAL8" "" "GAL-8x"; do
    fm_linear_identifier_valid "$bad" && fail "identifier must be rejected: '$bad'"
  done
  pass "issue identifier validation"
}

# --- authentication and transport refusals ----------------------------------

test_missing_key_refusal() {
  local home out rc=0
  home=$(make_home missing-key)
  rm -f "$home/.env"
  out=$(env -u LINEAR_API_KEY FM_HOME="$home" "$CLI" list 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "list without a key must refuse"
  assert_contains "$out" "LINEAR_API_KEY is missing" "missing-key refusal names the requirement"
  pass "missing key refuses with the concrete requirement"
}

test_rejected_key_refusal() {
  local home fb out rc=0
  home=$(make_home rejected-key)
  fb=$(make_fake_curl "$home")
  out=$(env FM_FAKE_CURL_STATUS=401 FM_FAKE_CURL_BODY='{"errors":[{"message":"Authentication required, not authenticated"}]}' \
    FM_HOME="$home" FM_FAKE_CURL_LOG="$home/curl.log" PATH="$fb:$PATH" "$CLI" viewer 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected key must refuse"
  assert_contains "$out" "rejected by Linear" "rejected-key refusal names the cause"
  pass "rejected key refuses loudly"
}

test_graphql_error_refusal() {
  local home fb out rc=0
  home=$(make_home gql-error)
  fb=$(make_fake_curl "$home")
  out=$(env FM_FAKE_CURL_FORCE_ERRORS=1 FM_HOME="$home" FM_FAKE_CURL_LOG="$home/curl.log" \
    PATH="$fb:$PATH" "$CLI" show ZZ-1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an errors[] payload must refuse"
  assert_contains "$out" "Something went wrong" "the GraphQL error message is surfaced"
  pass "GraphQL errors payload refuses"
}

test_transport_hides_key_from_argv() {
  local home fb
  home=$(make_home hidden-key)
  fb=$(make_fake_curl "$home")
  run_cli "$home" "$fb" viewer >/dev/null || fail "viewer request failed"
  grep -F 'lin_api_test_fixture' "$home/curl-args.log" >/dev/null \
    && fail "the Linear API key must not appear in curl argv"
  grep -Fx 'auth-file-ok' "$home/curl-auth.log" >/dev/null \
    || fail "the Authorization header must come from a private mode-0600 file"
  pass "transport keeps the Linear API key out of process argv"
}

# --- queue normalization ------------------------------------------------------

test_queue_bucket_mapping() {
  local home fb out
  home=$(make_home mapping)
  fb=$(make_fake_curl "$home")
  out=$(run_cli "$home" "$fb" list --json) || fail "list --json failed"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.identifier == "QB-1") | .bucket')" queued "backlog maps to queued"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.identifier == "QB-2") | .bucket')" queued "unstarted maps to queued"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.identifier == "QB-3") | .bucket')" queued "triage maps to queued"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.identifier == "QB-4") | .bucket')" in_flight "started maps to in_flight"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.identifier == "QB-5") | .bucket')" "done" "completed maps to done"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.identifier == "QB-6") | .bucket')" dropped "canceled maps to dropped"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.identifier == "QB-7") | .bucket')" dropped "duplicate maps to dropped"
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.identifier == "QB-8") | .bucket')" queued "an unknown state type stays visible as queued"
  pass "state-type to bucket mapping"
}

test_queue_text_grouping() {
  local home fb out
  home=$(make_home text)
  fb=$(make_fake_curl "$home")
  out=$(run_cli "$home" "$fb" list) || fail "list failed"
  assert_contains "$out" "queued:" "text output has a queued group"
  assert_contains "$out" "in flight:" "text output has an in-flight group"
  assert_contains "$out" "QB-4  Started item  [In Progress]" "started row renders its state name"
  assert_contains "$out" "QB-9" "captain-call row is listed"
  assert_contains "$out" "<captain-call>" "captain-call label is marked"
  pass "list text grouping"
}

test_queue_pagination() {
  local home fb out
  home=$(make_home paging)
  fb=$(make_fake_curl "$home")
  out=$(env FM_FAKE_CURL_PAGED=1 FM_HOME="$home" FM_FAKE_CURL_LOG="$home/curl.log" \
    PATH="$fb:$PATH" "$CLI" list --json) || fail "paginated list failed"
  assert_eq "$(printf '%s' "$out" | jq 'length')" 2 "both pages combined"
  assert_contains "$out" "PG-1" "first page row present"
  assert_contains "$out" "PG-2" "second page row present"
  pass "queue pagination follows the cursor"
}

# --- write verbs: request shapes ---------------------------------------------

test_start_moves_to_lowest_started_state() {
  local home fb out
  home=$(make_home start)
  fb=$(make_fake_curl "$home")
  out=$(run_cli "$home" "$fb" start GAL-8) || fail "start failed"
  assert_contains "$out" "started: GAL-8" "start reports the issue"
  grep -F 'issueUpdate(' "$home/curl.log" | grep -F '"state":"state-progress"' >/dev/null \
    || fail "start must move to the lowest-position started state (In Progress, not In Review)"
  pass "start uses the team's canonical started state"
}

test_done_attaches_pr_and_completes() {
  local home fb out
  home=$(make_home done-verb)
  fb=$(make_fake_curl "$home")
  out=$(run_cli "$home" "$fb" "done" GAL-8 --pr https://github.com/acme/repo/pull/7) || fail "done failed"
  assert_contains "$out" "completed: GAL-8" "done reports completion"
  grep -F 'attachmentLinkURL(' "$home/curl.log" | grep -F 'https://github.com/acme/repo/pull/7' >/dev/null \
    || fail "done --pr must attach the PR URL"
  grep -F 'issueUpdate(' "$home/curl.log" | grep -F '"state":"state-done"' >/dev/null \
    || fail "done must move to the completed state"
  pass "done attaches the PR and completes the issue"
}

test_done_requires_completion_artifact() {
  local home fb out rc=0
  home=$(make_home done-artifact)
  fb=$(make_fake_curl "$home")
  out=$(run_cli "$home" "$fb" "done" GAL-8 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "done without an artifact must refuse"
  assert_contains "$out" "requires a completion artifact" "done names its artifact requirement"
  [ ! -s "$home/curl.log" ] || fail "done without an artifact must refuse before calling Linear"
  pass "done refuses completion without an artifact"
}

test_hold_deduplicates_each_decision_comment() {
  local home fb out
  home=$(make_home hold)
  fb=$(make_fake_curl "$home")
  out=$(run_cli "$home" "$fb" hold GAL-8 --reason "pick a rollout window") || fail "hold failed"
  assert_contains "$out" "held: GAL-8" "hold reports the issue"
  grep -F 'issueAddLabel(' "$home/curl.log" >/dev/null || fail "hold must add the captain-call label"
  grep -F 'commentCreate(' "$home/curl.log" | grep -F 'Captain decision needed: pick a rollout window' >/dev/null \
    || fail "hold must post the decision-needed comment"
  : > "$home/curl.log"
  out=$(env FM_FAKE_ISSUE_LABELED=1 \
    FM_FAKE_COMMENTS_JSON='["Captain decision needed: pick a rollout window"]' \
    FM_HOME="$home" FM_FAKE_CURL_LOG="$home/curl.log" \
    PATH="$fb:$PATH" "$CLI" hold GAL-8 --reason "pick a rollout window") || fail "repeat hold failed"
  assert_contains "$out" "already held: GAL-8" "repeat hold reports already held"
  grep -F 'commentCreate(' "$home/curl.log" >/dev/null && fail "a repeat hold must not post another comment"
  : > "$home/curl.log"
  out=$(env FM_FAKE_ISSUE_LABELED=1 \
    FM_FAKE_COMMENTS_JSON='["Captain decision needed: pick a rollout window"]' \
    FM_HOME="$home" FM_FAKE_CURL_LOG="$home/curl.log" \
    PATH="$fb:$PATH" "$CLI" hold GAL-8 --reason "[release-key] choose the release train") \
    || fail "distinct hold failed"
  assert_contains "$out" "held: GAL-8" "distinct hold reports the issue"
  grep -F 'issueAddLabel(' "$home/curl.log" >/dev/null \
    && fail "a labeled issue must not add the shared label again"
  grep -F 'commentCreate(' "$home/curl.log" | grep -F '[release-key] choose the release train' >/dev/null \
    || fail "a distinct decision key must get its own comment"
  pass "hold idempotency is scoped to each exact decision comment"
}

test_resolve_comments_and_clears_label() {
  local home fb out
  home=$(make_home resolve)
  fb=$(make_fake_curl "$home")
  printf 'Ship the staged rollout.\n' > "$home/decision.md"
  out=$(env FM_FAKE_ISSUE_LABELED=1 FM_HOME="$home" FM_FAKE_CURL_LOG="$home/curl.log" \
    PATH="$fb:$PATH" "$CLI" resolve GAL-8 --decision-file "$home/decision.md") || fail "resolve failed"
  assert_contains "$out" "resolved: GAL-8" "resolve reports the issue"
  grep -F 'commentCreate(' "$home/curl.log" | grep -F 'Ship the staged rollout.' >/dev/null \
    || fail "resolve must post the recorded decision"
  grep -F 'issueRemoveLabel(' "$home/curl.log" >/dev/null || fail "resolve must clear the captain-call label"
  : > "$home/curl.log"
  out=$(env FM_FAKE_ISSUE_LABELED=1 FM_HOME="$home" FM_FAKE_CURL_LOG="$home/curl.log" \
    PATH="$fb:$PATH" "$CLI" resolve GAL-8 --decision-file "$home/decision.md" --keep-held) || fail "keep-held resolve failed"
  assert_contains "$out" "still held" "keep-held resolve says the hold remains"
  grep -F 'issueRemoveLabel(' "$home/curl.log" >/dev/null && fail "--keep-held must not clear the label"
  pass "resolve posts the decision and manages the label"
}

test_attach_pr_validates_url() {
  local home fb rc=0
  home=$(make_home attach)
  fb=$(make_fake_curl "$home")
  run_cli "$home" "$fb" attach-pr GAL-8 "not-a-url" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "attach-pr must reject a non-https URL"
  run_cli "$home" "$fb" attach-pr GAL-8 https://github.com/acme/repo/pull/7 >/dev/null \
    || fail "attach-pr with an https URL failed"
  grep -F 'attachmentLinkURL(' "$home/curl.log" >/dev/null || fail "attach-pr must send the attachment"
  pass "attach-pr validates and attaches"
}

# --- spawn --linear validation ------------------------------------------------

test_spawn_linear_validation() {
  local out rc
  rc=0; out=$("$ROOT/bin/fm-spawn.sh" lin-test /nonexistent --linear "bad id" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn must reject a malformed --linear identifier"
  assert_contains "$out" "expects a Linear issue identifier" "spawn names the identifier contract"
  rc=0; out=$("$ROOT/bin/fm-spawn.sh" lin-test --secondmate --linear GAL-8 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn must reject --linear with --secondmate"
  assert_contains "$out" "does not apply to secondmate" "spawn names the secondmate refusal"
  rc=0; out=$("$ROOT/bin/fm-spawn.sh" 'a=r1' 'b=r2' --linear GAL-8 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn must reject a shared --linear in batch mode"
  assert_contains "$out" "cannot be shared across a batch" "spawn names the batch refusal"
  pass "spawn --linear validation refusals"
}

# --- bearings projection under the linear backend ------------------------------

test_bearings_linear_projection() {
  local home fb out mate
  home=$(make_home bearings)
  fb=$(make_fake_curl "$home")
  mate="${home}-mate-home"
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-07-30)\n' \
    "$mate" > "$home/data/secondmates.md"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] mate-queued - Local queue row (repo: firstmate) (kind: ship)
- [ ] mate-decision - Choose a route (repo: firstmate) (kind: captain) (hold: captain choice pending) (hold-kind: captain)

## Done
- [x] mate-landed - Local landed row https://github.com/acme/repo/pull/40 (repo: firstmate) (kind: ship) (merged 2026-07-30)
EOF
  printf 'window=fm-local-task\nendpoint_task_id=local-task\nlinear=QB-9\n' > "$home/state/local-task.meta"
  printf 'linear=QB-4\n' > "$home/state/stale-task.meta"
  out=$(env FM_HOME="$home" FM_FAKE_CURL_LOG="$home/curl.log" PATH="$fb:$PATH" "$BEARINGS" --json) \
    || fail "bearings under the linear backend failed"
  assert_eq "$(printf '%s' "$out" | jq -r '.backlog_backend')" linear "model carries the backend marker"
  assert_eq "$(printf '%s' "$out" | jq -r '.gates[] | select(.id == "QB-1") | .owner')" linear "queued Linear issue appears as a gate owned by linear"
  printf '%s' "$out" | jq -e '.gates | map(.id) | index("QB-9") | not' >/dev/null \
    || fail "a captain-call issue must not appear as an ordinary gate"
  assert_eq "$(printf '%s' "$out" | jq -r '.decisions_open[] | select(.id == "QB-9") | .verb')" captain-hold "captain-call issue appears as an open decision"
  assert_eq "$(printf '%s' "$out" | jq -r '.landed[] | select(.id == "QB-5") | .artifact')" "https://linear.app/x/issue/QB-5" "completed Linear issue appears as landed with its URL"
  printf '%s' "$out" | jq -e '.gates | map(.id) | index("mate-queued") | not' >/dev/null \
    || fail "a secondmate-home queued row must not appear beside the Linear queue"
  printf '%s' "$out" | jq -e '.landed | map(.id) | index("mate-landed") | not' >/dev/null \
    || fail "a secondmate-home landed row must not appear beside Linear completions"
  printf '%s' "$out" | jq -e '.decisions_open | map(.id) | index("mate/mate-decision") != null' >/dev/null \
    || fail "a local secondmate captain hold must remain load-bearing under Linear"
  printf '%s' "$out" | jq -e '.omitted[] | select(.surface == "secondmate-home queued backlog row(s) superseded by the Linear queue: 1")' >/dev/null \
    || fail "excluded secondmate-home queued rows must be disclosed"
  printf '%s' "$out" | jq -e '.omitted[] | select(.surface == "secondmate-home landed backlog row(s) superseded by the Linear queue: 1")' >/dev/null \
    || fail "excluded secondmate-home landed rows must be disclosed"
  printf '%s' "$out" | jq -e '.omitted[] | select(.surface | contains("QB-4"))' >/dev/null \
    || fail "a stale linked meta must not suppress an in-flight Linear disclosure"
  pass "bearings sources gates, decisions, and landed from Linear"
}

test_retry_command_quotes_completion_note() {
  local rendered
  # shellcheck source=bin/fm-linear-lib.sh disable=SC1091
  . "$ROOT/bin/fm-linear-lib.sh"
  rendered=$(fm_linear_command_string bin/fm-backlog-linear.sh done GAL-8 --note "landed on local main")
  assert_eq "$rendered" "bin/fm-backlog-linear.sh done GAL-8 --note 'landed on local main'" \
    "retry command preserves a spaced completion note"
  pass "retry command is copy-paste runnable"
}

test_bearings_refuses_without_key() {
  local home out rc=0
  home=$(make_home bearings-nokey)
  rm -f "$home/.env"
  out=$(env -u LINEAR_API_KEY FM_HOME="$home" "$BEARINGS" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "bearings under linear without a key must refuse"
  assert_contains "$out" "LINEAR_API_KEY is missing" "bearings refusal names the requirement"
  pass "bearings refuses without the key instead of rendering an empty queue"
}

test_bearings_default_backend_untouched() {
  local home out
  home=$(make_home default-backend)
  rm -f "$home/config/backlog-backend"
  out=$(env -u LINEAR_API_KEY FM_HOME="$home" "$BEARINGS" --json) \
    || fail "bearings on the default backend failed"
  printf '%s' "$out" | jq -e 'has("backlog_backend") | not' >/dev/null \
    || fail "the default backend must not carry the linear marker"
  pass "default backend output carries no linear surface"
}

test_backend_selection
test_identifier_validation
test_missing_key_refusal
test_rejected_key_refusal
test_graphql_error_refusal
test_transport_hides_key_from_argv
test_queue_bucket_mapping
test_queue_text_grouping
test_queue_pagination
test_start_moves_to_lowest_started_state
test_done_attaches_pr_and_completes
test_done_requires_completion_artifact
test_hold_deduplicates_each_decision_comment
test_resolve_comments_and_clears_label
test_attach_pr_validates_url
test_spawn_linear_validation
test_bearings_linear_projection
test_bearings_refuses_without_key
test_bearings_default_backend_untouched
test_retry_command_quotes_completion_note

echo "all fm-linear-backend tests passed"
