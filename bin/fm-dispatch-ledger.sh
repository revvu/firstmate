#!/usr/bin/env bash
# Private outcome ledger for retired ship/scout dispatches.
# Usage:
#   fm-dispatch-ledger.sh append <meta-file> <status-file> <auto|done|failed|cancelled> [pr-url]
#   fm-dispatch-ledger.sh summarize [days]
#
# Teardown calls append under its task metadata lock, before removing that
# metadata. A separate POSIX file lock serializes all ledger writers. Atomic
# replacement and fsync keep retries safe: (task_id, spawn_gen) is recorded once.
# A record with no spawn_gen (predating the field, in a home whose backlog gate
# never stamps one) is recorded under the stable token 'legacy' rather than
# refused: teardown appends after its destructive steps, so a refusal here
# would strand the task with no way to retire it, and the stable token keeps
# the (task_id, spawn_gen) retry key deduplicating.
# FM_DATA_OVERRIDE or FM_HOME/data owns dispatch-ledger.jsonl and its .lock.
# An existing ledger that append cannot read back (a corrupt or foreign line)
# never blocks retirement: it is quarantined aside under a timestamped
# .corrupt- suffix - renamed, never deleted or overwritten - and a fresh ledger
# takes the row. summarize stays strict about the live file and warns while any
# quarantined ledger remains, so the corruption is repaired rather than silent.
# started_at is taken from metadata, then the spawn generation timestamp; legacy
# records without either retain null. ended_at is the retirement timestamp.
# auto uses the last done/failed/cancelled status event, otherwise done after
# teardown's completion gates. Forced discards pass cancelled unless explicitly
# overridden with teardown --outcome. No outcome inference from agent exit codes.
# Secondmate homes are persistent supervisors, not task dispatches, and are skipped.
# summarize groups the past seven days by kind, lane, mode, and outcome (or days).
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
export FM_HOME
case "${1:-}" in
  --help|-h|'') sed -n '2,/^set -eu/{ /^set -eu/d; s/^# *//; p; }' "$0"; exit 0 ;;
esac
exec python3 - "$@" <<'PY'
import collections
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile


def utc(epoch=None):
    instant = dt.datetime.now(dt.timezone.utc) if epoch is None else dt.datetime.fromtimestamp(epoch, dt.timezone.utc)
    return instant.isoformat().replace('+00:00', 'Z')


def read_rows(path):
    if not path.exists():
        return []
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    for row in rows:
        if not isinstance(row, dict) or not row.get('task_id') or not row.get('spawn_gen'):
            raise ValueError('invalid existing ledger row; refusing to replace it')
    return rows


def quarantine(path):
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    target = path.with_name(path.name + '.corrupt-' + stamp)
    serial = 0
    while target.exists():
        serial += 1
        target = path.with_name(path.name + '.corrupt-' + stamp + '.' + str(serial))
    os.rename(path, target)
    return target


def main():
    data = Path(os.environ.get('FM_DATA_OVERRIDE', Path(os.environ['FM_HOME']) / 'data'))
    path = data / 'dispatch-ledger.jsonl'
    command, *args = sys.argv[1:]
    if command == 'summarize':
        for stray in sorted(data.glob(path.name + '.corrupt-*')):
            print('warning: dispatch ledger: quarantined corrupt ledger at ' + str(stray)
                  + '; repair and merge or remove it by hand', file=sys.stderr)
        days = int(args[0]) if args else 7
        if len(args) > 1 or days < 1:
            raise ValueError('summarize requires positive days')
        cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
        counts = collections.Counter()
        for row in read_rows(path):
            if dt.datetime.fromisoformat(row['ended_at'].replace('Z', '+00:00')) >= cutoff:
                counts[tuple(row[key] for key in ('kind', 'harness', 'model', 'effort', 'mode', 'outcome'))] += 1
        print('kind\tharness\tmodel\teffort\tmode\toutcome\tcount')
        for group, count in sorted(counts.items()):
            print('\t'.join((*group, str(count))))
        return
    if command != 'append' or len(args) not in (3, 4):
        raise ValueError('expected append <meta> <status> <outcome> [pr-url] or summarize [days]')
    meta_path, status_path, outcome = args[:3]
    if outcome not in ('auto', 'done', 'failed', 'cancelled'):
        raise ValueError('invalid outcome')
    meta = {}
    for line in Path(meta_path).read_text().splitlines():
        key, sep, value = line.partition('=')
        if sep:
            meta[key] = value
    if meta.get('kind') == 'secondmate':
        return
    generation = meta.get('spawn_gen') or 'legacy'
    if outcome == 'auto':
        outcome = 'done'
        if Path(status_path).exists():
            for line in Path(status_path).read_text().splitlines():
                event = line.partition(':')[0]
                if event in ('done', 'failed', 'cancelled'):
                    outcome = event
    started = meta.get('started_at')
    match = re.match(r'^s([0-9]+)\.', generation)
    if not started and match:
        started = utc(int(match[1]))
    row = dict(task_id=Path(meta_path).stem, spawn_gen=generation,
               kind=meta.get('kind') or 'ship',
               harness=meta.get('harness') or 'unknown', model=meta.get('model') or 'default',
               effort=meta.get('effort') or 'default', mode=meta.get('mode') or 'no-mistakes',
               outcome=outcome, pr=(args[3] if len(args) == 4 else '') or meta.get('pr') or None,
               started_at=started, ended_at=utc())
    data.mkdir(parents=True, exist_ok=True)
    # Stable lock inode: only the data file is replaced. Never delete the lock.
    with (data / 'dispatch-ledger.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            rows = read_rows(path)
        except (OSError, ValueError):
            quarantined = quarantine(path)
            print('warning: dispatch ledger: unreadable ledger quarantined at ' + str(quarantined)
                  + '; starting a fresh ledger so retirement can proceed - repair and merge or'
                  ' remove it by hand', file=sys.stderr)
            rows = []
        if any((r['task_id'], r['spawn_gen']) == (row['task_id'], generation) for r in rows):
            return
        fd, temporary = tempfile.mkstemp(prefix='.dispatch-ledger-', dir=data)
        try:
            with os.fdopen(fd, 'w') as output:
                for item in rows + [row]:
                    output.write(json.dumps(item, separators=(',', ':')) + '\n')
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
            directory = os.open(data, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


try:
    main()
except (OSError, ValueError, KeyError, TypeError) as error:
    print('error: dispatch ledger: ' + str(error), file=sys.stderr)
    raise SystemExit(1)
PY
