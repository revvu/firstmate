#!/usr/bin/env bash
# fm-cswap-pick.sh - pick the claude-swap (cswap) account with the most
# remaining quota and print the Claude config root a worker launch selects.
#
# Usage:
#   fm-cswap-pick.sh [--model <model>]
#
# Output (stdout, one line): <number><TAB><email><TAB><root>
#   root is `ordinary` when the picked account is cswap's active default
#   login, else the absolute path of that account's cswap session profile:
#   the same CLAUDE_CONFIG_DIR that `cswap run <number>` launches under.
#   bin/fm-worker-account-lib.sh consumes that line for a home whose
#   config/claude-account holds `cswap`; docs/configuration.md "Worker
#   account pin" owns the operator contract.
# Exit 0 with a pick; 1 when cswap is not on PATH, lists no usable account,
#   or the session profile cannot be prepared (one error line on stderr);
#   2 on a usage error.
#
# Evidence: one `cswap list --json` call, nothing else. An account is usable
#   when it is not disabled and its usageStatus is ok with numeric fiveHour
#   and sevenDay percentages (utilization, 0..100). Remaining is 100 minus the
#   largest of the 5-hour window, the 7-day window, and, for a Fable model,
#   the Fable per-model window when cswap reports one. The highest remaining
#   wins; ties keep the active login, which needs no profile, then the
#   lowest account number.
#
# Session profiles are cswap's: a missing one is prepared with
#   `cswap run <number> --require-session -- --version`, which seeds the
#   profile under cswap's backup root and exits with Claude's version line;
#   --require-session refuses to touch the active login. This script never
#   switches the default login, so a `cswap auto` loop keeps rotating it
#   exactly as before, and the two never contend: auto owns the default
#   login, workers run in per-account session profiles.
set -u

MODEL=''
while [ $# -gt 0 ]; do
  case "$1" in
    --model) [ $# -ge 2 ] || { echo "error: --model needs a value" >&2; exit 2; }; MODEL=$2; shift 2 ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v cswap >/dev/null 2>&1 || { echo "error: cswap is not on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 1; }

fable=false
case "$MODEL" in
  *[Ff]able*) fable=true ;;
esac

listing=$(cswap list --json 2>/dev/null) || { echo "error: cswap list --json failed" >&2; exit 1; }
pick=$(printf '%s\n' "$listing" | jq -r --argjson fable "$fable" '
  [ .accounts[]?
    | select((.disabled // false) | not)
    | select(.usageStatus == "ok")
    | select((.usage.fiveHour.pct | type) == "number" and (.usage.sevenDay.pct | type) == "number")
    | . as $a
    | ([$a.usage.fiveHour.pct, $a.usage.sevenDay.pct]
       + (if $fable
          then [$a.usage.scoped[]? | select(((.name // "") | ascii_downcase) == "fable") | .pct | select(type == "number")]
          else [] end)) as $used
    | {number, email, active: (.active // false), remaining: (100 - ($used | max))}
  ]
  | sort_by(-.remaining, (if .active then 0 else 1 end), .number)
  | first // empty
  | [.number, .email, (if .active then "active" else "profile" end)]
  | @tsv' 2>/dev/null) || { echo "error: cswap list --json is not a usable account listing" >&2; exit 1; }
[ -n "$pick" ] || { echo "error: no usable claude-swap account (enabled, usageStatus ok); run cswap list to refresh usage" >&2; exit 1; }

number=${pick%%$'\t'*}
rest=${pick#*$'\t'}
email=${rest%%$'\t'*}
kind=${rest#*$'\t'}

if [ "$kind" = active ]; then
  printf '%s\t%s\tordinary\n' "$number" "$email"
  exit 0
fi

# cswap's backup root (claude_swap/paths.py get_backup_root): XDG data on
# Linux, the legacy ~/.claude-swap-backup elsewhere.
case "$(uname -s 2>/dev/null)" in
  Linux)
    xdg=${XDG_DATA_HOME:-}
    case "$xdg" in
      "~"*) xdg="$HOME${xdg#"~"}" ;;
    esac
    case "$xdg" in
      /*) backup="$xdg/claude-swap" ;;
      *) backup="$HOME/.local/share/claude-swap" ;;
    esac
    ;;
  *) backup="$HOME/.claude-swap-backup" ;;
esac
slug=$(printf '%s' "$email" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g')
root="$backup/sessions/$number-$slug"
if [ ! -d "$root" ]; then
  cswap run "$number" --require-session -- --version >/dev/null 2>&1 \
    || { echo "error: cswap run $number --require-session could not prepare the session profile for $email" >&2; exit 1; }
  [ -d "$root" ] || { echo "error: cswap run $number left no session profile at $root" >&2; exit 1; }
fi
printf '%s\t%s\t%s\n' "$number" "$email" "$root"
