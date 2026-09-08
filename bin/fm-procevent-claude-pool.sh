#!/usr/bin/env bash
# Read-only pooled Claude awareness using cswap's observed schema-2 cache.
# Usage:
#   fm-procevent-claude-pool.sh arm [--interval <seconds>]
#   fm-procevent-claude-pool.sh snapshot
#   fm-procevent-claude-pool.sh poll [--interval <seconds>]
#   fm-procevent-claude-pool.sh classify <result-file>
#   fm-procevent-claude-pool.sh silent <result-file>
#   fm-procevent-claude-pool.sh terminal <result-file>
#   fm-procevent-claude-pool.sh retire
#
# arm registers source claude-pool on the existing process-event runner.
# snapshot prints JSON without changing caches or private state. poll waits for
# a state transition relative to the last DURABLE capture, then prints JSON.
# Healthy recovery is captured silently; low/exhausted/unknown wake firstmate.
# The source stays registered until retire; handled acknowledgements belong to
# firstmate. Nothing here selects a harness, starts work, or swaps credentials.
#
# FM_CONFIG_OVERRIDE or FM_HOME/config owns claude-pool-reserve (0-100 percent
# remaining, default 10). CLAUDE_SWAP_HOME selects the cache root (default
# ~/.claude-swap-backup).
# Cache observations older than 30 minutes, failed observations, missing account
# windows, or expired nonzero windows are unknown, never assumed available.
# Enabled subscription slots contribute 100 - max(5h, 7d, all reported scoped
# pct) percentage points each. remaining_percent divides that sum by slot count;
# this is equal-account capacity awareness, not a token or billing estimate.
# API-key slots are excluded, matching cswap auto without paid fallback.
# Exhausted means all known enabled slots have zero remaining. Nearest reset
# names the earliest exhausted window; usable_reset is min(per-slot max(tight
# window resets)), so a short reset cannot hide another tight weekly window.
# Pool tightness uses 90% used per slot, matching the documented cswap invocation.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
export FM_HOME
case "${1:-}" in
  arm)
    shift
    exec "$SCRIPT_DIR/fm-procevent.sh" register claude-pool claude-pool -- \
      env "FM_HOME=$FM_HOME" "CLAUDE_SWAP_HOME=${CLAUDE_SWAP_HOME:-$HOME/.claude-swap-backup}" \
      "$SCRIPT_DIR/fm-procevent-claude-pool.sh" poll "$@"
    ;;
  retire) exec "$SCRIPT_DIR/fm-procevent.sh" retire claude-pool ;;
  terminal) exit 1 ;;
  --help|-h|'') sed -n '2,/^set -eu/{ /^set -eu/d; s/^# *//; p; }' "$0"; exit 0 ;;
esac
exec python3 - "$@" <<'PY'
import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import time

parser = argparse.ArgumentParser()
parser.add_argument('command', choices=['snapshot', 'poll', 'classify', 'silent'])
parser.add_argument('result', nargs='?')
parser.add_argument('--interval', type=float, default=60)
args = parser.parse_args()
if not math.isfinite(args.interval) or args.interval <= 0:
    parser.error('interval must be positive and finite')

home = Path(os.environ['FM_HOME'])
state = Path(os.environ.get('FM_STATE_OVERRIDE', home / 'state'))
config_dir = Path(os.environ.get('FM_CONFIG_OVERRIDE', home / 'config'))
cache = Path(os.environ.get('CLAUDE_SWAP_HOME', Path.home() / '.claude-swap-backup'))


def percent(value):
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        raise ValueError('missing or invalid percentage')
    if not math.isfinite(value) or not 0 <= value <= 100:
        raise ValueError('percentage outside 0-100')
    return value


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError('missing reset time')
    result = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('reset time has no timezone')
    return result.timestamp()


def iso(value):
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat().replace('+00:00', 'Z')


def snapshot():
    now = time.time()
    result = {'status': 'unknown', 'observed_at': iso(now)}
    try:
        reserve_path = config_dir / 'claude-pool-reserve'
        reserve = percent(float(reserve_path.read_text().strip())) if reserve_path.exists() else 10
        result['reserve_percent'] = reserve
        usage = json.loads((cache / 'cache/usage.json').read_text())
        sequence = json.loads((cache / 'sequence.json').read_text())
        if usage.get('schemaVersion') != 2:
            raise ValueError('unsupported usage schema')
        accounts = sequence['accounts']
        if not isinstance(accounts, dict) or not isinstance(usage['accounts'], dict):
            raise ValueError('accounts must be objects')
        slots = []
        for slot, config in accounts.items():
            if not isinstance(config, dict) or not isinstance(config.get('disabled', False), bool):
                raise ValueError('invalid account configuration')
            if config.get('disabled') or config.get('kind') == 'api_key':
                continue
            row = usage['accounts'].get(slot, {})
            fetched = row.get('fetchedAt')
            if (not isinstance(fetched, (int, float)) or isinstance(fetched, bool)
                    or not math.isfinite(fetched) or not 0 <= now - fetched <= 1800
                    or row.get('lastError') or row.get('authDeadStrikes', 0)):
                raise ValueError('enabled slot has stale, failed, or missing usage')
            good = row['lastGood']
            scoped = good.get('scoped', [])
            if not isinstance(scoped, list):
                raise ValueError('scoped windows must be an array')
            windows = [good['five_hour'], good['seven_day']] + scoped
            parsed = []
            for window in windows:
                used = percent(window['pct'])
                reset = timestamp(window['resets_at']) if window.get('resets_at') else None
                if used > 0 and reset is not None and reset <= now:
                    raise ValueError('enabled slot needs usage refreshed after reset')
                parsed.append((used, reset))
            slots.append(parsed)
        if not slots:
            raise ValueError('no enabled subscription slots')
        remaining = [100 - max(pct for pct, _ in windows) for windows in slots]
        total = sum(remaining)
        result.update(enabled_slots=len(slots), remaining_points=total,
                      remaining_percent=total / len(slots),
                      all_tight=all(value <= 10 for value in remaining))
        exhausted = all(value == 0 for value in remaining)
        result['status'] = 'exhausted' if exhausted else 'low' if total / len(slots) < reserve else 'healthy'
        blocked = [[reset for pct, reset in windows if pct >= 90] for windows in slots]
        floor = 100 if exhausted else 90
        known_resets = [reset for windows in slots for pct, reset in windows
                        if pct >= floor and reset is not None]
        # A partial time is not a promise that the pool will be usable then.
        complete = all(windows and all(reset is not None for reset in windows) for windows in blocked)
        result['nearest_reset'] = iso(min(known_resets)) if known_resets else None
        result['usable_reset'] = iso(min(max(windows) for windows in blocked)) if complete else None
        if exhausted:
            result['message'] = 'Claude pool exhausted; nearest reset: ' + (result['nearest_reset'] or 'unknown (missing reset data)')
        elif result['status'] == 'low':
            result['message'] = 'Claude pool below reserve; ask before starting new Claude crewmates'
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        result['status'] = 'unknown'
        result['message'] = 'Claude pool awareness unavailable: ' + str(error)
    return result


def read_result(path):
    try:
        result = json.loads(path.read_text())
        if result.get('status') in ('healthy', 'low', 'exhausted', 'unknown'):
            return result
    except (OSError, ValueError, AttributeError):
        pass
    return {'status': 'unknown'}


if args.command in ('classify', 'silent'):
    if not args.result:
        parser.error('result file required')
    status = read_result(Path(args.result))['status']
    if args.command == 'silent':
        raise SystemExit(0 if status == 'healthy' else 1)
    print(status)
elif args.command == 'snapshot':
    print(json.dumps(snapshot(), separators=(',', ':')))
else:
    # The runner serializes this source. Reading its immutable capture avoids
    # losing an alert to a crash between updating an adapter marker and capture.
    captures = []
    for path in (state / 'procevent-inbox').glob('claude-pool.*.result'):
        number = path.name.split('.')[-2]
        if number.isdigit() and not path.is_symlink():
            captures.append((int(number), path))
    previous = read_result(max(captures)[1])['status'] if captures else None
    while True:
        result = snapshot()
        if result['status'] != previous:
            print(json.dumps(result, separators=(',', ':')), flush=True)
            break
        time.sleep(args.interval)
PY
