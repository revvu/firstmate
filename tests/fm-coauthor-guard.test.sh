#!/usr/bin/env bash
# Mechanical co-author guard: agent trailers stripped in the bound task
# worktree only, project hooks chained, primary checkout untouched, unbind on
# removal, and bare common repos keep core.bare through the config migration.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-coauthor-guard)
fm_git_identity
GUARD="$ROOT/bin/fm-coauthor-guard.sh"

REPO="$LAB/repo"
WT="$LAB/wt"
HOOKS="$LAB/task-tmp/hooks"
fm_git_worktree "$REPO" "$WT" task-branch

# The project's own hook manager: a repo-config core.hooksPath whose hooks must
# keep running inside the guarded task worktree.
mkdir -p "$REPO/.projecthooks"
printf '#!/bin/sh\ntouch %s\n' "$LAB/pre-commit-ran" > "$REPO/.projecthooks/pre-commit"
printf '#!/bin/sh\ntouch %s\n' "$LAB/prior-commit-msg-ran" > "$REPO/.projecthooks/commit-msg"
chmod 755 "$REPO/.projecthooks/pre-commit" "$REPO/.projecthooks/commit-msg"
git -C "$REPO" config core.hooksPath "$REPO/.projecthooks"

"$GUARD" install "$WT" "$HOOKS"
# Reinstall is the relaunch path: it must rebind cleanly, not chain to itself.
"$GUARD" install "$WT" "$HOOKS"

echo change > "$WT/file.txt"
git -C "$WT" add file.txt
git -C "$WT" commit -qm 'feat: work

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Co-authored-by: Human Person <human@example.com>'
msg=$(git -C "$WT" log -1 --pretty=%B)
assert_not_contains "$msg" 'anthropic.com' 'task worktree commit kept a Claude co-author trailer'
assert_contains "$msg" 'Human Person <human@example.com>' 'task worktree commit lost a human co-author trailer'
assert_present "$LAB/pre-commit-ran" 'project pre-commit hook did not run under the guard'
assert_present "$LAB/prior-commit-msg-ran" 'project commit-msg hook was not chained by the guard'

git -C "$WT" commit --allow-empty -qm 'chore: variants

Co-authored-by: Cursor Agent <cursoragent@cursor.com>
Co-authored-by: Copilot <175728472+Copilot@users.noreply.github.com>'
msg=$(git -C "$WT" log -1 --pretty=%B)
assert_not_contains "$msg" 'Co-authored-by' 'task worktree commit kept a Cursor or Copilot co-author trailer'

# The primary checkout is unaffected: the binding is worktree-scoped.
echo primary > "$REPO/primary.txt"
git -C "$REPO" add primary.txt
git -C "$REPO" commit -qm 'primary work

Co-authored-by: Claude Fable 5 <noreply@anthropic.com>'
msg=$(git -C "$REPO" log -1 --pretty=%B)
assert_contains "$msg" 'noreply@anthropic.com' 'primary checkout commit lost its trailer to the task guard'

# remove unbinds the guard, returning the pooled worktree to the project's own
# hooks path: an agent trailer lands again and the strip hook is out of force.
"$GUARD" remove "$WT"
git -C "$WT" commit --allow-empty -qm 'after unbind

Co-authored-by: Claude Fable 5 <noreply@anthropic.com>'
msg=$(git -C "$WT" log -1 --pretty=%B)
assert_contains "$msg" 'noreply@anthropic.com' 'worktree still strips trailers after guard removal'

# A bare common repository with linked worktrees (the no-mistakes gate layout):
# enabling extensions.worktreeConfig must migrate core.bare so the bare repo
# stays bare, while the guarded worktree still strips agent trailers.
BARE="$REPO.origin.git"
git -C "$BARE" worktree add -q -b bare-task "$LAB/bwt" HEAD
"$GUARD" install "$LAB/bwt" "$LAB/bare-hooks"
[ "$(git -C "$BARE" rev-parse --is-bare-repository)" = true ] \
  || fail 'bare common repository lost core.bare after the guard config migration'
git -C "$LAB/bwt" commit --allow-empty -qm 'bare-layout work

Co-authored-by: Claude Fable 5 <noreply@anthropic.com>'
msg=$(git -C "$LAB/bwt" log -1 --pretty=%B)
assert_not_contains "$msg" 'anthropic.com' 'bare-layout task worktree kept an agent co-author trailer'

pass 'co-author guard strips agent trailers per worktree, chains project hooks, spares the primary, unbinds, and keeps bare repos bare'
