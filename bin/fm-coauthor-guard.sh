#!/usr/bin/env bash
# Mechanical agent co-author guard for isolated task worktrees.
# Usage:
#   fm-coauthor-guard.sh install <worktree> <hooks-dir>
#   fm-coauthor-guard.sh remove <worktree>
#
# install binds a task-private commit-msg hook to ONE worktree through git's
# per-worktree configuration: it enables extensions.worktreeConfig in the
# repository's common config (first migrating core.bare/core.worktree into the
# main worktree's config.worktree, the same relocation git's own
# sparse-checkout bootstrap performs), then sets a worktree-scoped
# core.hooksPath to <hooks-dir>. The generated commit-msg hook strips known
# agent Co-authored-by trailers before a commit lands, so the no-agent-trailer
# rule holds even when a worker ignores its launch instruction. Any previously
# effective commit-msg hook is chained first, and every other previously
# effective hook is delegated through an exec shim, so a project's own hook
# manager (a repo-config core.hooksPath or plain .git/hooks content) keeps
# running inside the task worktree. Nothing is written to the shared
# .git/hooks directory or to any tracked project file: the binding lives in
# this worktree's own config.worktree, so the primary checkout and sibling
# worktrees are unaffected. remove unsets the worktree-scoped core.hooksPath
# so a pooled worktree returns to the pool clean; the hooks dir itself is
# task-private temp space that its owner (fm-teardown's task-tmp removal)
# deletes.
set -eu

case "${1:-}" in
  --help|-h|'') sed -n '2,/^set -eu/{ /^set -eu/d; s/^# *//; p; }' "$0"; exit 0 ;;
esac

sq() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

write_commit_msg_hook() {
  local hook=$1 prior_hook=$2
  cat > "$hook" <<EOF
#!/bin/sh
# Firstmate mechanical co-author guard (bin/fm-coauthor-guard.sh): strips
# known agent Co-authored-by trailers from this task worktree's commit
# messages after chaining the previously effective commit-msg hook.
prior=$(sq "$prior_hook")
if [ -x "\$prior" ]; then
  "\$prior" "\$@" || exit \$?
fi
msg=\$1
tmp=\$msg.fm-coauthor-guard
grep -v -i -E \\
  -e '^[[:space:]]*co-authored-by:[[:space:]]*(claude|cursor|codex|chatgpt|gemini|google-labs|jules|copilot|opencode|aider|devin|grok|kimi|rovo)([^[:alnum:]]|\$)' \\
  -e '^[[:space:]]*co-authored-by:[^<]*<[^>]*@(anthropic\\.com|cursor\\.com|cursor\\.sh|openai\\.com|moonshot\\.cn)>' \\
  "\$msg" > "\$tmp" || :
mv "\$tmp" "\$msg"
EOF
  chmod 755 "$hook"
}

install_guard() {
  local wt=$1 hooks_dir=$2 common_dir prior key val hook name
  case "$hooks_dir" in
    /?*) : ;;
    *) echo "error: coauthor guard requires an absolute hooks dir, got '${hooks_dir:-none}'" >&2; return 1 ;;
  esac
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: $wt is not a git worktree; cannot bind the co-author guard" >&2
    return 1
  fi
  common_dir=$(git -C "$wt" rev-parse --git-common-dir) || return 1
  case "$common_dir" in /*) : ;; *) common_dir="$wt/$common_dir" ;; esac
  if [ "$(git -C "$wt" config --get extensions.worktreeConfig 2>/dev/null || true)" != true ]; then
    for key in core.bare core.worktree; do
      if val=$(git config --file "$common_dir/config" --get "$key" 2>/dev/null); then
        git config --file "$common_dir/config.worktree" "$key" "$val" || return 1
        git config --file "$common_dir/config" --unset-all "$key" || return 1
      fi
    done
    git -C "$wt" config extensions.worktreeConfig true || return 1
  fi
  # A pooled worktree can arrive with a retired task's binding; drop it before
  # reading the project's own effective hooks path.
  git -C "$wt" config --worktree --unset-all core.hooksPath 2>/dev/null || true
  prior=$(git -C "$wt" config --type=path --get core.hooksPath 2>/dev/null || true)
  [ -n "$prior" ] || prior=$(git -C "$wt" rev-parse --git-path hooks) || return 1
  case "$prior" in /*) : ;; *) prior="$wt/$prior" ;; esac
  rm -rf "$hooks_dir"
  mkdir -p "$hooks_dir"
  if [ -d "$prior" ]; then
    for hook in "$prior"/*; do
      [ -f "$hook" ] && [ -x "$hook" ] || continue
      name=$(basename "$hook")
      case "$name" in *.sample|commit-msg) continue ;; esac
      printf '#!/bin/sh\nexec %s "$@"\n' "$(sq "$hook")" > "$hooks_dir/$name"
      chmod 755 "$hooks_dir/$name"
    done
  fi
  write_commit_msg_hook "$hooks_dir/commit-msg" "$prior/commit-msg"
  git -C "$wt" config --worktree core.hooksPath "$hooks_dir"
}

remove_guard() {
  local wt=$1
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$wt" config --worktree --unset-all core.hooksPath 2>/dev/null || true
}

command=$1
shift
case "$command" in
  install)
    [ $# -eq 2 ] || { echo 'error: usage: fm-coauthor-guard.sh install <worktree> <hooks-dir>' >&2; exit 1; }
    install_guard "$1" "$2"
    ;;
  remove)
    [ $# -eq 1 ] || { echo 'error: usage: fm-coauthor-guard.sh remove <worktree>' >&2; exit 1; }
    remove_guard "$1"
    ;;
  *)
    echo "error: unknown command '$command'; expected install or remove" >&2
    exit 1
    ;;
esac
