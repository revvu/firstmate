#!/usr/bin/env bash
# fm-backlog-linear.sh - the queue lifecycle CLI for the Linear backlog backend.
#
# docs/linear-backend.md owns setup, the queue definition, the state mapping,
# and limits; bin/fm-linear-lib.sh owns the request mechanics this wraps.
# Every command requires curl, jq, and LINEAR_API_KEY (environment, else
# $FM_HOME/.env) and refuses with the concrete missing requirement otherwise.
# Comments posted to Linear are sparse and factual: at most one per real
# milestone, never step-by-step progress.
#
# Usage:
#   fm-backlog-linear.sh viewer
#   fm-backlog-linear.sh list [--json]
#   fm-backlog-linear.sh show <issue>
#   fm-backlog-linear.sh add <title> [--team <key>] [--body <text>]
#   fm-backlog-linear.sh start <issue>
#   fm-backlog-linear.sh done <issue> [--pr <url>] [--report <path>] [--note <text>]
#   fm-backlog-linear.sh hold <issue> --reason <text>
#   fm-backlog-linear.sh resolve <issue> [--decision-file <path>] [--keep-held]
#   fm-backlog-linear.sh attach-pr <issue> <pr-url>
#
# list    - the durable queue: non-archived issues assigned to the key's viewer
#           or unassigned, grouped queued / in flight / done / dropped.
# start   - move the issue to its team's canonical started state (dispatch).
# done    - attach the completion artifact (--pr as a link attachment, --report
#           or --note as one terse comment), then move to completed.
# hold    - mirror a captain decision: add the captain-call label plus one
#           comment stating the decision needed (idempotent; a second hold on
#           an already-labeled issue posts nothing).
# resolve - post the recorded decision when --decision-file is given, then
#           remove the captain-call label; --keep-held posts the decision but
#           leaves the label because other decisions on the issue remain open.
# add     - create an issue; --team is required unless the workspace has
#           exactly one team.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-linear-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-linear-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-backlog-linear: %s\n' "$*" >&2
  exit 1
}

require_identifier() {  # <value>
  fm_linear_identifier_valid "${1:-}" \
    || fail "expected a Linear issue identifier like GAL-8, got: ${1:-}"
}

command_viewer() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  fm_linear_viewer_json | jq -r '"\(.name) <\(.email)>"'
}

command_list() {
  local format=text queue
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) format=json ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  queue=$(fm_linear_queue_json) || exit 1
  if [ "$format" = json ]; then
    printf '%s\n' "$queue" | jq .
    return 0
  fi
  printf '%s\n' "$queue" | jq -r --arg captain "$FM_LINEAR_CAPTAIN_LABEL" '
    def rows($bucket): [ .[] | select(.bucket == $bucket) ]
      | if length == 0 then "  (none)"
        else (sort_by(.updated) | reverse | .[]
              | "  \(.identifier)  \(.title)  [\(.state_name)]"
                + (if .assignee then " (\(.assignee))" else "" end)
                + (if (.labels | index($captain)) then " <\($captain)>" else "" end))
        end;
    "queue: \(length) issue(s) (viewer-assigned + unassigned, non-archived)",
    "queued:", rows("queued"),
    "in flight:", rows("in_flight"),
    "done:", rows("done"),
    "dropped:", rows("dropped")'
}

command_show() {
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  require_identifier "$1"
  fm_linear_issue_json "$1" | jq -r "$FM_LINEAR_BUCKET_JQ"'
    "issue: \(.identifier)  \(.title)",
    "url: \(.url)",
    "state: \(.state.name) (\(.state.type) -> \(.state.type | fm_bucket))",
    "team: \(.team.key)",
    "assignee: \(.assignee.name // "unassigned")",
    "labels: \(if (.labels.nodes | length) > 0 then [.labels.nodes[].name] | join(", ") else "(none)" end)",
    "attachments:",
    (if (.attachments.nodes | length) > 0
     then (.attachments.nodes[] | "  \(.title // "-")  \(.url)")
     else "  (none)" end),
    "",
    (.description // "(no description)")'
}

command_add() {
  local title=${1:-} team_key='' body='' teams team_id
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  [ -n "$title" ] || fail "a non-empty title is required"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --team) shift; team_key=${1:-} ;;
      --body) shift; body=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  teams=$(fm_linear_teams_json) || exit 1
  if [ -n "$team_key" ]; then
    team_id=$(printf '%s' "$teams" | jq -r --arg k "$team_key" '.[] | select(.key == $k) | .id')
    [ -n "$team_id" ] || fail "no team with key $team_key (teams: $(printf '%s' "$teams" | jq -r '[.[].key] | join(", ")'))"
  elif [ "$(printf '%s' "$teams" | jq 'length')" = 1 ]; then
    team_id=$(printf '%s' "$teams" | jq -r '.[0].id')
  else
    fail "--team <key> is required in a multi-team workspace (teams: $(printf '%s' "$teams" | jq -r '[.[].key] | join(", ")'))"
  fi
  fm_linear_create "$team_id" "$title" "$body"
}

command_start() {
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  require_identifier "$1"
  fm_linear_move "$1" started
  printf 'started: %s\n' "$1"
}

command_done() {
  local id=${1:-} pr='' report='' note='' issue uuid
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  require_identifier "$id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pr) shift; pr=${1:-} ;;
      --report) shift; report=${1:-} ;;
      --note) shift; note=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  issue=$(fm_linear_issue_json "$id") || exit 1
  uuid=$(printf '%s' "$issue" | jq -r '.id')
  if [ -n "$pr" ]; then
    fm_linear_attach_url "$uuid" "$pr" "Pull request"
  fi
  if [ -n "$report" ]; then
    fm_linear_comment "$uuid" "Completed - report at $report in the firstmate home."
  elif [ -n "$note" ]; then
    fm_linear_comment "$uuid" "Completed - $note"
  fi
  fm_linear_move "$id" completed
  printf 'completed: %s\n' "$id"
}

command_hold() {
  local id=${1:-} reason='' issue uuid label_id
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  require_identifier "$id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) shift; reason=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  [ -n "$reason" ] || fail "--reason <text> is required"
  issue=$(fm_linear_issue_json "$id") || exit 1
  uuid=$(printf '%s' "$issue" | jq -r '.id')
  if printf '%s' "$issue" | jq -e --arg l "$FM_LINEAR_CAPTAIN_LABEL" \
    '.labels.nodes | any(.name == $l)' >/dev/null; then
    printf 'already held: %s\n' "$id"
    return 0
  fi
  label_id=$(fm_linear_label_id "$FM_LINEAR_CAPTAIN_LABEL" "$(printf '%s' "$issue" | jq -r '.team.id')") || exit 1
  fm_linear_label_add "$uuid" "$label_id"
  fm_linear_comment "$uuid" "Captain decision needed: $reason"
  printf 'held: %s\n' "$id"
}

command_resolve() {
  local id=${1:-} decision_file='' decision='' keep_held=0 issue uuid label_id
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  require_identifier "$id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --keep-held) keep_held=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  if [ -n "$decision_file" ]; then
    [ -f "$decision_file" ] || fail "decision file does not exist: $decision_file"
    decision=$(cat "$decision_file")
    [ -n "$decision" ] || fail "decision file must not be empty"
  fi
  issue=$(fm_linear_issue_json "$id") || exit 1
  uuid=$(printf '%s' "$issue" | jq -r '.id')
  if [ -n "$decision" ]; then
    fm_linear_comment "$uuid" "Captain decision:

$decision"
  fi
  if [ "$keep_held" = 1 ]; then
    printf 'resolved: %s (still held for other open decisions)\n' "$id"
    return 0
  fi
  label_id=$(printf '%s' "$issue" | jq -r --arg l "$FM_LINEAR_CAPTAIN_LABEL" \
    '.labels.nodes[] | select(.name == $l) | .id')
  if [ -n "$label_id" ]; then
    fm_linear_label_remove "$uuid" "$label_id"
  fi
  printf 'resolved: %s\n' "$id"
}

command_attach_pr() {
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  require_identifier "$1"
  case "$2" in
    https://*) : ;;
    *) fail "expected an https PR URL, got: $2" ;;
  esac
  fm_linear_attach_url "$(fm_linear_issue_json "$1" | jq -r '.id')" "$2" "Pull request"
  printf 'attached: %s -> %s\n' "$2" "$1"
}

case "${1:-}" in
  viewer) shift; command_viewer "$@" ;;
  list) shift; command_list "$@" ;;
  show) shift; command_show "$@" ;;
  add) shift; command_add "$@" ;;
  start) shift; command_start "$@" ;;
  done) shift; command_done "$@" ;;
  hold) shift; command_hold "$@" ;;
  resolve) shift; command_resolve "$@" ;;
  attach-pr) shift; command_attach_pr "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
