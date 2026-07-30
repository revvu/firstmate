# shellcheck shell=bash
# Shared Linear backlog-backend helpers: backend selection, authentication,
# GraphQL transport, queue normalization, and the write primitives the
# lifecycle needs. docs/linear-backend.md owns setup, the queue definition,
# and the state mapping rationale; this file owns the exact mechanics.
# Usage: . bin/fm-linear-lib.sh   (callers must have FM_HOME set before any
# key or request helper runs; FM_CONFIG_OVERRIDE keeps its usual meaning)
#
# Auth: LINEAR_API_KEY from the environment wins, else the last assignment in
# $FM_LINEAR_ENV_FILE (default $FM_HOME/.env). The key is sent only as the
# Authorization header and is never echoed, logged, or embedded in errors.
# Transport: POST ${FM_LINEAR_URL:-https://api.linear.app/graphql} via curl,
# bounded by FM_LINEAR_TIMEOUT (default 30s) per request.
# Observed live 2026-07-30: a personal API key authenticates as the bare
# Authorization value (no Bearer prefix); a rejected key returns HTTP 401 with
# errors[0].extensions.code=AUTHENTICATION_ERROR.
#
# The single-quoted GraphQL literals below intentionally carry GraphQL $variables
# that must never be shell-expanded; values travel via jq --arg only.
# shellcheck disable=SC2016

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fm-x-lib.sh"

# Single owner of the Linear state-type -> queue-bucket mapping, as a jq def so
# every normalization applies the identical contract. Observed live 2026-07-30:
# this workspace's teams carry backlog, unstarted, started, completed, canceled,
# and duplicate state types. Unknown future types stay visible as queued rather
# than vanishing.
FM_LINEAR_BUCKET_JQ='def fm_bucket:
  if . == "started" then "in_flight"
  elif . == "completed" then "done"
  elif . == "canceled" or . == "cancelled" or . == "duplicate" then "dropped"
  else "queued" end;'

# The queue definition (docs/linear-backend.md): non-archived issues assigned
# to the viewer OR unassigned, across every team in the workspace.
FM_LINEAR_QUEUE_FILTER='{"or":[{"assignee":{"isMe":{"eq":true}}},{"assignee":{"null":true}}]}'

# Single owner of the captain-decision mirror label name (docs/linear-backend.md).
FM_LINEAR_CAPTAIN_LABEL=${FM_LINEAR_CAPTAIN_LABEL:-captain-call}

fm_linear_backend_selected() {  # <config_dir>
  [ "$(fm_backlog_backend_value "$1")" = linear ]
}

fm_linear_env_file() {
  printf '%s\n' "${FM_LINEAR_ENV_FILE:-$FM_HOME/.env}"
}

fm_linear_api_key() {
  if [ -n "${LINEAR_API_KEY+x}" ]; then
    printf '%s' "${LINEAR_API_KEY-}"
    return 0
  fi
  fmx_env_get LINEAR_API_KEY "$(fm_linear_env_file)"
}

# Validate the requirements for any Linear call and refuse with the concrete
# missing requirement. Never proceeds partially.
fm_linear_require() {
  command -v curl >/dev/null 2>&1 \
    || { echo "fm-linear: curl is required for the Linear backlog backend" >&2; return 1; }
  command -v jq >/dev/null 2>&1 \
    || { echo "fm-linear: jq is required for the Linear backlog backend" >&2; return 1; }
  [ -n "$(fm_linear_api_key)" ] \
    || { echo "fm-linear: LINEAR_API_KEY is missing - add LINEAR_API_KEY=<key> to $(fm_linear_env_file) (see docs/linear-backend.md)" >&2; return 1; }
}

# fm_linear_gql <query> [<variables-json>] - POST one GraphQL request.
# Prints the response body on success; prints a sanitized diagnostic to stderr
# and returns non-zero on transport failure, HTTP error, rejected key, or a
# GraphQL errors[] payload.
fm_linear_gql() {
  local query=$1 vars=${2:-null} key payload response status body message header_file
  fm_linear_require || return 1
  key=$(fm_linear_api_key)
  payload=$(jq -cn --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}') \
    || { echo "fm-linear: could not encode the request" >&2; return 1; }
  response=$(
    header_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-linear-header.XXXXXX") \
      || exit 1
    trap 'rm -f "$header_file"' EXIT HUP INT TERM
    printf 'Authorization: %s\n' "$key" > "$header_file" || exit 1
    printf '%s' "$payload" | curl -sS --max-time "${FM_LINEAR_TIMEOUT:-30}" \
      -X POST "${FM_LINEAR_URL:-https://api.linear.app/graphql}" \
      -H "@$header_file" -H "Content-Type: application/json" \
      --data-binary @- -w '\n%{http_code}' 2>/dev/null
  ) \
    || { echo "fm-linear: request to Linear failed (network or curl error)" >&2; return 1; }
  status=${response##*$'\n'}
  body=${response%$'\n'*}
  if [ "$status" = 401 ]; then
    echo "fm-linear: LINEAR_API_KEY was rejected by Linear - refresh the key in $(fm_linear_env_file)" >&2
    return 1
  fi
  message=$(printf '%s' "$body" | jq -r '.errors[0].message // empty' 2>/dev/null) || message=""
  if [ "$status" != 200 ] || [ -n "$message" ]; then
    [ -n "$message" ] || message="HTTP $status"
    echo "fm-linear: Linear returned an error: $message" >&2
    return 1
  fi
  printf '%s\n' "$body"
}

fm_linear_command_string() {
  local arg separator=
  for arg in "$@"; do
    printf '%s' "$separator"
    case "$arg" in
      '') printf "''" ;;
      *[!A-Za-z0-9_@%+=:,./-]*)
        printf "'"
        printf '%s' "$arg" | sed "s/'/'\\\\''/g"
        printf "'"
        ;;
      *) printf '%s' "$arg" ;;
    esac
    separator=' '
  done
}

fm_linear_identifier_valid() {  # <issue-identifier like GAL-8>
  case "$1" in
    *[!A-Za-z0-9-]*|''|-*|*-) return 1 ;;
  esac
  case "$1" in
    *-*) : ;;
    *) return 1 ;;
  esac
  case "${1##*-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# fm_linear_queue_json - the full normalized queue as one JSON array of
# {identifier,title,url,state_name,state_type,bucket,assignee,labels,updated,completed}.
# Paginates at 100 per page up to FM_LINEAR_MAX_PAGES (default 5) pages and
# reports a hit cap to stderr instead of truncating silently.
fm_linear_queue_json() {
  local query cursor=null page=0 max_pages=${FM_LINEAR_MAX_PAGES:-5} body rows='[]' has_next
  query='query($filter: IssueFilter, $first: Int, $after: String) {
    issues(filter: $filter, first: $first, after: $after) {
      nodes { identifier title url updatedAt completedAt
              state { name type } assignee { name }
              labels { nodes { name } } }
      pageInfo { hasNextPage endCursor } } }'
  while :; do
    body=$(fm_linear_gql "$query" \
      "$(jq -cn --argjson f "$FM_LINEAR_QUEUE_FILTER" --argjson a "$cursor" '{filter:$f, first:100, after:$a}')") \
      || return 1
    rows=$(jq -cn --argjson acc "$rows" --argjson page "$(printf '%s' "$body" | jq -c '.data.issues.nodes')" '$acc + $page') \
      || { echo "fm-linear: unexpected queue response shape" >&2; return 1; }
    has_next=$(printf '%s' "$body" | jq -r '.data.issues.pageInfo.hasNextPage')
    [ "$has_next" = true ] || break
    page=$((page + 1))
    if [ "$page" -ge "$max_pages" ]; then
      echo "fm-linear: queue capped at $((max_pages * 100)) issues; raise FM_LINEAR_MAX_PAGES for more" >&2
      break
    fi
    cursor=$(printf '%s' "$body" | jq -c '.data.issues.pageInfo.endCursor')
  done
  printf '%s\n' "$rows" | jq -c "$FM_LINEAR_BUCKET_JQ"'
    [ .[] | {identifier, title, url,
             state_name: .state.name, state_type: .state.type,
             bucket: (.state.type | fm_bucket),
             assignee: (.assignee.name // null),
             labels: [.labels.nodes[].name],
             updated: .updatedAt, completed: .completedAt} ]'
}

# fm_linear_issue_json <identifier> - one full issue node (id, identifier,
# title, url, state, team, labels with ids, attachments). Live-verified: the
# issue(id:) query accepts the human identifier (e.g. GAL-8) as well as a UUID.
fm_linear_issue_json() {
  local body
  body=$(fm_linear_gql 'query($id: String!) { issue(id: $id) {
      id identifier title url description
      state { id name type } team { id key }
      assignee { name }
      labels { nodes { id name } }
      attachments { nodes { url title } } } }' \
    "$(jq -cn --arg id "$1" '{id:$id}')") || return 1
  printf '%s' "$body" | jq -ce '.data.issue' \
    || { echo "fm-linear: issue $1 was not found" >&2; return 1; }
}

fm_linear_issue_comments_json() {
  local query cursor=null body page comments='[]' has_next
  query='query($id: String!, $first: Int, $after: String) {
    issue(id: $id) {
      comments(first: $first, after: $after) {
        nodes { body }
        pageInfo { hasNextPage endCursor } } } }'
  while :; do
    body=$(fm_linear_gql "$query" \
      "$(jq -cn --arg id "$1" --argjson after "$cursor" \
        '{id:$id, first:100, after:$after}')") || return 1
    page=$(printf '%s' "$body" | jq -ce '[.data.issue.comments.nodes[].body]') \
      || { echo "fm-linear: could not read comments for issue $1" >&2; return 1; }
    comments=$(jq -cn --argjson a "$comments" --argjson b "$page" '$a + $b')
    has_next=$(printf '%s' "$body" | jq -r '.data.issue.comments.pageInfo.hasNextPage')
    [ "$has_next" = true ] || break
    cursor=$(printf '%s' "$body" | jq -c '.data.issue.comments.pageInfo.endCursor')
    [ "$cursor" != null ] \
      || { echo "fm-linear: comment pagination returned no cursor for issue $1" >&2; return 1; }
  done
  printf '%s\n' "$comments"
}

# fm_linear_team_state_id <team-uuid> <state-type> - the team's canonical state
# of that type (lowest position wins, e.g. In Progress over In Review).
fm_linear_team_state_id() {
  local body
  body=$(fm_linear_gql 'query($id: String!) { team(id: $id) {
      states { nodes { id name type position } } } }' \
    "$(jq -cn --arg id "$1" '{id:$id}')") || return 1
  printf '%s' "$body" | jq -re --arg t "$2" \
    '[.data.team.states.nodes[] | select(.type == $t)] | sort_by(.position) | .[0].id' \
    || { echo "fm-linear: team has no state of type $2" >&2; return 1; }
}

# fm_linear_move <identifier> <state-type> - move an issue to its team's
# canonical state of the given type.
fm_linear_move() {
  local issue state_id uuid body
  issue=$(fm_linear_issue_json "$1") || return 1
  uuid=$(printf '%s' "$issue" | jq -r '.id')
  state_id=$(fm_linear_team_state_id "$(printf '%s' "$issue" | jq -r '.team.id')" "$2") || return 1
  body=$(fm_linear_gql 'mutation($id: String!, $state: String!) {
      issueUpdate(id: $id, input: { stateId: $state }) { success } }' \
    "$(jq -cn --arg id "$uuid" --arg state "$state_id" '{id:$id, state:$state}')") || return 1
  printf '%s' "$body" | jq -e '.data.issueUpdate.success == true' >/dev/null \
    || { echo "fm-linear: Linear did not confirm the state change for $1" >&2; return 1; }
}

# fm_linear_comment <issue-uuid> <body-text> - post one comment.
fm_linear_comment() {
  local body
  body=$(fm_linear_gql 'mutation($id: String!, $body: String!) {
      commentCreate(input: { issueId: $id, body: $body }) { success } }' \
    "$(jq -cn --arg id "$1" --arg body "$2" '{id:$id, body:$body}')") || return 1
  printf '%s' "$body" | jq -e '.data.commentCreate.success == true' >/dev/null \
    || { echo "fm-linear: Linear did not confirm the comment" >&2; return 1; }
}

fm_linear_comment_once() {
  local comments
  comments=$(fm_linear_issue_comments_json "$1") || return 1
  if printf '%s' "$comments" | jq -e --arg comment "$3" 'index($comment) != null' >/dev/null; then
    printf 'existing\n'
    return 0
  fi
  fm_linear_comment "$2" "$3" || return 1
  printf 'posted\n'
}

# fm_linear_attach_url <issue-uuid> <url> <title> - attach one link.
fm_linear_attach_url() {
  local body
  body=$(fm_linear_gql 'mutation($id: String!, $url: String!, $title: String!) {
      attachmentLinkURL(issueId: $id, url: $url, title: $title) { success } }' \
    "$(jq -cn --arg id "$1" --arg url "$2" --arg title "$3" '{id:$id, url:$url, title:$title}')") || return 1
  printf '%s' "$body" | jq -e '.data.attachmentLinkURL.success == true' >/dev/null \
    || { echo "fm-linear: Linear did not confirm the attachment" >&2; return 1; }
}

# fm_linear_label_id <name> <issue-team-uuid> - resolve a label id by name,
# preferring a workspace label, then the issue's own team's label, creating a
# workspace label when none exists.
fm_linear_label_id() {
  local body id
  body=$(fm_linear_gql 'query($name: String!) {
      issueLabels(filter: { name: { eq: $name } }, first: 20) {
        nodes { id name team { id } } } }' \
    "$(jq -cn --arg name "$1" '{name:$name}')") || return 1
  id=$(printf '%s' "$body" | jq -r --arg team "$2" '.data.issueLabels.nodes
    | (map(select(.team == null)) + map(select(.team.id == $team)))
    | .[0].id // empty')
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
    return 0
  fi
  body=$(fm_linear_gql 'mutation($name: String!) {
      issueLabelCreate(input: { name: $name }) { success issueLabel { id } } }' \
    "$(jq -cn --arg name "$1" '{name:$name}')") || return 1
  printf '%s' "$body" | jq -re '.data.issueLabelCreate.issueLabel.id' \
    || { echo "fm-linear: could not create the $1 label" >&2; return 1; }
}

# fm_linear_label_add <issue-uuid> <label-id>
fm_linear_label_add() {
  local body
  body=$(fm_linear_gql 'mutation($id: String!, $label: String!) {
      issueAddLabel(id: $id, labelId: $label) { success } }' \
    "$(jq -cn --arg id "$1" --arg label "$2" '{id:$id, label:$label}')") || return 1
  printf '%s' "$body" | jq -e '.data.issueAddLabel.success == true' >/dev/null \
    || { echo "fm-linear: Linear did not confirm the label add" >&2; return 1; }
}

# fm_linear_label_remove <issue-uuid> <label-id>
fm_linear_label_remove() {
  local body
  body=$(fm_linear_gql 'mutation($id: String!, $label: String!) {
      issueRemoveLabel(id: $id, labelId: $label) { success } }' \
    "$(jq -cn --arg id "$1" --arg label "$2" '{id:$id, label:$label}')") || return 1
  printf '%s' "$body" | jq -e '.data.issueRemoveLabel.success == true' >/dev/null \
    || { echo "fm-linear: Linear did not confirm the label removal" >&2; return 1; }
}

# fm_linear_teams_json - id/key/name for every team (bounded to the first 50).
fm_linear_teams_json() {
  local body
  body=$(fm_linear_gql 'query { teams(first: 50) { nodes { id key name } } }') || return 1
  printf '%s' "$body" | jq -c '.data.teams.nodes'
}

# fm_linear_create <team-uuid> <title> <body> - create one issue; prints
# "<identifier> <url>".
fm_linear_create() {
  local body
  body=$(fm_linear_gql 'mutation($team: String!, $title: String!, $desc: String) {
      issueCreate(input: { teamId: $team, title: $title, description: $desc }) {
        success issue { identifier url } } }' \
    "$(jq -cn --arg team "$1" --arg title "$2" --arg desc "$3" \
      '{team:$team, title:$title, desc:(if $desc == "" then null else $desc end)}')") || return 1
  printf '%s' "$body" | jq -re '.data.issueCreate.issue | "\(.identifier) \(.url)"' \
    || { echo "fm-linear: Linear did not confirm the issue creation" >&2; return 1; }
}

# fm_linear_viewer_json - the authenticated identity {id,name,email}.
fm_linear_viewer_json() {
  local body
  body=$(fm_linear_gql 'query { viewer { id name email } }') || return 1
  printf '%s' "$body" | jq -c '.data.viewer'
}
