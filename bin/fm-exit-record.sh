#!/usr/bin/env bash
# fm-exit-record.sh - the ONE owner of a launched agent process's exit record.
#
# Why this exists: firstmate could tell the captain that a worker stopped, but
# never why. On 2026-08-10 five concurrently running agents terminated within
# 0.6s of each other and left no first-party trace at all - no error, no signal,
# no shutdown record - so the cause could not be established afterwards. Every
# other lifecycle signal firstmate owns (turn-end markers, the semantic
# busy-state contract) describes what the agent was DOING; none of them survives
# the agent's own death. This record is the missing one: what the launched
# process returned, and what the host looked like when it did.
#
# Mechanism (deliberately not a poller - firstmate supervision is wake-driven):
# bin/fm-spawn.sh ARMS the record before launch, then appends this script to the
# pane's launch line, so the pane shell itself completes the record the instant
# the agent returns. No process watches anything. Every runtime backend drives
# its endpoint through the same shell text-send path, so the capture rides the
# launch command and is backend-independent rather than per-adapter code.
#
# Record file: state/<id>.exit - key=value lines, atomically replaced. It has
# exactly two lifecycle states, and telling them apart is itself evidence:
#
#   ARMED     armed_* fields only. The recorder never ran: either the agent is
#             still running, or the pane shell died WITH it (which points at the
#             terminal/session/host, not the agent process).
#   RECORDED  armed_* plus exit_* fields. The agent process returned and the
#             pane shell was alive to say so.
#
# An ABSENT record, an armed-only record, and an unreadable record all read as
# UNKNOWN. None of them ever reads as a clean exit: inferring success from
# absent evidence is the exact failure this record exists to remove.
#
# Fields:
#   v=1                     record format version
#   id=<task id>
#   armed_at / armed_utc    when spawn armed the record
#   armed_<snapshot>        host resource snapshot at spawn (see below)
#   exit_status=<n>         the pane shell's $? for the launched agent
#   exit_at / exit_utc      when the agent returned
#   exit_signal=<n|none>    see the signal-derivation limit below
#   exit_signal_name=<NAME|none>
#   exit_signal_basis=exit-status-convention|none
#   exit_disposition=clean|abnormal   clean is exit_status=0 and nothing else
#   exit_<snapshot>         host resource snapshot at exit
#
# Host resource snapshot (<prefix>_mem_free_mb, _mem_total_mb, _mem_compressed_mb,
# _swap_used_mb, _swap_total_mb, _load1): three cheap reads, `unknown` wherever
# the platform does not supply the figure. It is here because the 2026-08-10
# incident's only surviving hypothesis was memory pressure and there was no
# captured figure to test it against - the host was reconstructed by hand hours
# later. A snapshot at spawn and at exit makes that hypothesis checkable from the
# record instead of re-argued from scratch. It is CORRELATION, never a cause:
# nothing in firstmate reads these fields to make a decision.
#
# Signal-derivation limit, stated because the record must not overclaim: a POSIX
# shell reports a foreground command killed by signal N as exit status 128+N,
# and there is no second channel to separate that from a program that
# deliberately exited 128+N. exit_signal is therefore derived from that
# convention and exit_signal_basis names it, so a reader can see the inference
# rather than inherit it silently. Statuses outside 129..192 record no signal.
#
# Deliberately NOT done here: this script never appends to state/<id>.status and
# never wakes firstmate. It is instrumentation - the watcher's existing stale
# detection surfaces the stopped worker exactly as it does today, and
# bin/fm-crew-state.sh then reports THIS record instead of "state: unknown".
# Emitting a wake would make a harness's own nonzero quit look like a failure.
#
# Usage:
#   fm-exit-record.sh arm <state-dir> <id>
#   fm-exit-record.sh record <state-dir> <id> <exit-status>
#   fm-exit-record.sh retire <state-dir> <id>
#   fm-exit-record.sh show <state-dir> <id>
#   fm-exit-record.sh -h | --help
#
# `show` prints exactly one tab-separated line for machine reads:
#   <none|armed|recorded-clean|recorded-abnormal|unreadable><TAB><one-line summary>
# and always exits 0 on a successful read; exit 2 is a usage error only.
set -u

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
}

die() {
  printf 'fm-exit-record: %s\n' "$*" >&2
  exit 2
}

record_path() {  # <state-dir> <id>
  printf '%s/%s.exit' "$1" "$2"
}

# --- host resource snapshot -------------------------------------------------
# Prints "<prefix>_<field>=<value>" lines. Every field is always printed; a
# figure this platform does not supply is the literal `unknown`, never empty and
# never zero, so a reader can never mistake "not measured" for "measured zero".

snapshot_unknown() {  # <prefix>
  local p=$1 f
  for f in mem_free_mb mem_total_mb mem_compressed_mb swap_used_mb swap_total_mb load1; do
    printf '%s_%s=unknown\n' "$p" "$f"
  done
}

snapshot_darwin() {  # <prefix>
  local p=$1 pagesize vmstat total swap
  local free=unknown compressed=unknown mem_total=unknown
  local swap_used=unknown swap_total=unknown load1=unknown
  vmstat=$(vm_stat 2>/dev/null || true)
  if [ -n "$vmstat" ]; then
    pagesize=$(printf '%s\n' "$vmstat" | sed -n '1s/.*page size of \([0-9][0-9]*\) bytes.*/\1/p')
    case "$pagesize" in ''|*[!0-9]*) pagesize= ;; esac
    if [ -n "$pagesize" ]; then
      free=$(printf '%s\n' "$vmstat" | sed -n 's/^Pages free: *\([0-9][0-9]*\)\..*/\1/p' | head -1)
      compressed=$(printf '%s\n' "$vmstat" \
        | sed -n 's/^Pages occupied by compressor: *\([0-9][0-9]*\)\..*/\1/p' | head -1)
      case "$free" in ''|*[!0-9]*) free=unknown ;; *) free=$((free * pagesize / 1048576)) ;; esac
      case "$compressed" in
        ''|*[!0-9]*) compressed=unknown ;;
        *) compressed=$((compressed * pagesize / 1048576)) ;;
      esac
    fi
  fi
  total=$(sysctl -n hw.memsize 2>/dev/null || true)
  case "$total" in ''|*[!0-9]*) mem_total=unknown ;; *) mem_total=$((total / 1048576)) ;; esac
  # `sysctl -n vm.swapusage` prints: total = 16384.00M  used = 14847.75M  free = ...
  swap=$(sysctl -n vm.swapusage 2>/dev/null || true)
  if [ -n "$swap" ]; then
    swap_total=$(printf '%s\n' "$swap" | sed -n 's/.*total = *\([0-9][0-9]*\)\.[0-9]*M.*/\1/p')
    swap_used=$(printf '%s\n' "$swap" | sed -n 's/.*used = *\([0-9][0-9]*\)\.[0-9]*M.*/\1/p')
    case "$swap_total" in ''|*[!0-9]*) swap_total=unknown ;; esac
    case "$swap_used" in ''|*[!0-9]*) swap_used=unknown ;; esac
  fi
  # `sysctl -n vm.loadavg` prints: { 28.51 29.02 28.66 }
  load1=$(sysctl -n vm.loadavg 2>/dev/null | sed -n 's/^{ *\([0-9][0-9.]*\) .*/\1/p')
  [ -n "$load1" ] || load1=unknown
  printf '%s_mem_free_mb=%s\n' "$p" "$free"
  printf '%s_mem_total_mb=%s\n' "$p" "$mem_total"
  printf '%s_mem_compressed_mb=%s\n' "$p" "$compressed"
  printf '%s_swap_used_mb=%s\n' "$p" "$swap_used"
  printf '%s_swap_total_mb=%s\n' "$p" "$swap_total"
  printf '%s_load1=%s\n' "$p" "$load1"
}

snapshot_linux() {  # <prefix>
  local p=$1 meminfo kb
  local free=unknown mem_total=unknown swap_used=unknown swap_total=unknown load1=unknown
  local swap_free=
  meminfo=$(cat /proc/meminfo 2>/dev/null || true)
  if [ -n "$meminfo" ]; then
    kb=$(printf '%s\n' "$meminfo" | sed -n 's/^MemAvailable: *\([0-9][0-9]*\) kB/\1/p' | head -1)
    [ -n "$kb" ] || kb=$(printf '%s\n' "$meminfo" | sed -n 's/^MemFree: *\([0-9][0-9]*\) kB/\1/p' | head -1)
    case "$kb" in ''|*[!0-9]*) free=unknown ;; *) free=$((kb / 1024)) ;; esac
    kb=$(printf '%s\n' "$meminfo" | sed -n 's/^MemTotal: *\([0-9][0-9]*\) kB/\1/p' | head -1)
    case "$kb" in ''|*[!0-9]*) mem_total=unknown ;; *) mem_total=$((kb / 1024)) ;; esac
    kb=$(printf '%s\n' "$meminfo" | sed -n 's/^SwapTotal: *\([0-9][0-9]*\) kB/\1/p' | head -1)
    case "$kb" in ''|*[!0-9]*) swap_total=unknown ;; *) swap_total=$((kb / 1024)) ;; esac
    swap_free=$(printf '%s\n' "$meminfo" | sed -n 's/^SwapFree: *\([0-9][0-9]*\) kB/\1/p' | head -1)
    case "$swap_free" in ''|*[!0-9]*) swap_free= ;; esac
    if [ "$swap_total" != unknown ] && [ -n "$swap_free" ]; then
      # swap_total is already MB here; swap_free is still the raw kB reading.
      swap_used=$((swap_total - (swap_free / 1024)))
    fi
  fi
  load1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || true)
  [ -n "$load1" ] || load1=unknown
  printf '%s_mem_free_mb=%s\n' "$p" "$free"
  printf '%s_mem_total_mb=%s\n' "$p" "$mem_total"
  # Linux does not expose a compressed-memory footprint comparable to the Darwin
  # compressor page count, so it stays explicitly unmeasured.
  printf '%s_mem_compressed_mb=unknown\n' "$p"
  printf '%s_swap_used_mb=%s\n' "$p" "$swap_used"
  printf '%s_swap_total_mb=%s\n' "$p" "$swap_total"
  printf '%s_load1=%s\n' "$p" "$load1"
}

host_snapshot() {  # <prefix>
  case "$(uname -s 2>/dev/null || true)" in
    Darwin) snapshot_darwin "$1" ;;
    Linux)  snapshot_linux "$1" ;;
    *)      snapshot_unknown "$1" ;;
  esac
}

# --- signal derivation ------------------------------------------------------

signal_of_status() {  # <status> -> signal number, or empty
  local st=$1
  case "$st" in ''|*[!0-9]*) return 0 ;; esac
  [ "$st" -ge 129 ] && [ "$st" -le 192 ] || return 0
  printf '%s' "$((st - 128))"
}

signal_name_of() {  # <signal number> -> NAME, or empty
  local n=$1 name
  name=$(kill -l "$n" 2>/dev/null) || return 0
  name=${name%%[[:space:]]*}
  case "$name" in
    ''|*[!A-Za-z0-9_]*) return 0 ;;
  esac
  printf '%s' "$name"
}

# --- write ------------------------------------------------------------------

atomic_write() {  # <path> ; body on stdin
  local path=$1 tmp
  tmp="$path.tmp.$$"
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

cmd_arm() {  # <state-dir> <id>
  local state=$1 id=$2 path now
  [ -d "$state" ] || die "state directory does not exist: $state"
  path=$(record_path "$state" "$id")
  now=$(date +%s)
  {
    printf 'v=1\n'
    printf 'id=%s\n' "$id"
    printf 'armed_at=%s\n' "$now"
    printf 'armed_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    host_snapshot armed
  } | atomic_write "$path" || die "could not write $path"
}

cmd_record() {  # <state-dir> <id> <exit-status>
  local state=$1 id=$2 status=$3 path armed now signal name basis disposition
  path=$(record_path "$state" "$id")
  case "$status" in ''|*[!0-9]*) status=unknown ;; esac
  # Preserve the armed half verbatim: it carries the spawn-time snapshot this
  # record exists to compare against. A missing armed half (record removed, or
  # a task spawned before exit capture existed) still records the exit rather
  # than dropping the one fact the caller has.
  armed=$(grep -E '^(v|id|armed_)' "$path" 2>/dev/null || true)
  [ -n "$armed" ] || armed=$(printf 'v=1\nid=%s\narmed_at=unknown\narmed_utc=unknown\n' "$id")
  now=$(date +%s)
  signal=$(signal_of_status "$status")
  if [ -n "$signal" ]; then
    name=$(signal_name_of "$signal")
    [ -n "$name" ] || name=unknown
    basis=exit-status-convention
  else
    signal=none
    name=none
    basis=none
  fi
  if [ "$status" = 0 ]; then disposition=clean; else disposition=abnormal; fi
  {
    printf '%s\n' "$armed"
    printf 'exit_status=%s\n' "$status"
    printf 'exit_at=%s\n' "$now"
    printf 'exit_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'exit_signal=%s\n' "$signal"
    printf 'exit_signal_name=%s\n' "$name"
    printf 'exit_signal_basis=%s\n' "$basis"
    printf 'exit_disposition=%s\n' "$disposition"
    host_snapshot exit
  } | atomic_write "$path" || die "could not write $path"
}

cmd_retire() {  # <state-dir> <id>
  local state=$1 id=$2 path
  [ -d "$state" ] || die "state directory does not exist: $state"
  path=$(record_path "$state" "$id")
  rm -f -- "$path" || die "could not remove $path"
}

# --- read -------------------------------------------------------------------

field() {  # <file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# One short clause naming whatever host pressure figures the record actually
# carries, or empty when the platform supplied none. Deliberately terse: it is a
# correlation clue in a one-line state read, not an analysis.
pressure_clause() {  # <file> <prefix>
  local file=$1 p=$2 free swap_used load parts=
  free=$(field "$file" "${p}_mem_free_mb")
  swap_used=$(field "$file" "${p}_swap_used_mb")
  load=$(field "$file" "${p}_load1")
  case "$free" in ''|unknown) ;; *) parts="${free}MB free" ;; esac
  case "$swap_used" in
    ''|unknown) ;;
    *) [ -n "$parts" ] && parts="$parts, "; parts="${parts}${swap_used}MB swap used" ;;
  esac
  case "$load" in
    ''|unknown) ;;
    *) [ -n "$parts" ] && parts="$parts, "; parts="${parts}load $load" ;;
  esac
  [ -n "$parts" ] || return 0
  printf 'host at %s: %s' "$p" "$parts"
}

cmd_show() {  # <state-dir> <id>
  local state=$1 id=$2 path v status disposition expected_disposition signal expected_signal name expected_name basis expected_basis
  local utc armed_utc detail pressure
  path=$(record_path "$state" "$id")
  if [ ! -f "$path" ]; then
    printf 'none\t\n'
    return 0
  fi
  v=$(field "$path" v)
  if [ "$v" != 1 ]; then
    printf 'unreadable\tagent exit record unreadable (format %s)\n' "${v:-missing}"
    return 0
  fi
  status=$(field "$path" exit_status)
  armed_utc=$(field "$path" armed_utc)
  if [ -z "$status" ]; then
    detail="agent exit not recorded"
    case "$armed_utc" in
      ''|unknown) detail="$detail (exit capture armed)" ;;
      *) detail="$detail (exit capture armed $armed_utc)" ;;
    esac
    printf 'armed\t%s\n' "$detail"
    return 0
  fi
  disposition=$(field "$path" exit_disposition)
  signal=$(field "$path" exit_signal)
  name=$(field "$path" exit_signal_name)
  basis=$(field "$path" exit_signal_basis)
  utc=$(field "$path" exit_utc)
  case "$status" in
    ''|*[!0-9]*|????*)
      printf 'unreadable\tagent exit record unreadable (exit status %s)\n' "${status:-missing}"
      return 0
      ;;
  esac
  if [ "$status" -gt 255 ]; then
    printf 'unreadable\tagent exit record unreadable (exit status %s)\n' "$status"
    return 0
  fi
  if [ "$status" -eq 0 ]; then expected_disposition=clean; else expected_disposition=abnormal; fi
  case "$disposition" in
    clean|abnormal) ;;
    *)
      printf 'unreadable\tagent exit record unreadable (exit disposition %s)\n' "${disposition:-missing}"
      return 0
      ;;
  esac
  if [ "$disposition" != "$expected_disposition" ]; then
    printf 'unreadable\tagent exit record unreadable (exit disposition conflicts with status %s)\n' "$status"
    return 0
  fi
  disposition=$expected_disposition
  expected_signal=$(signal_of_status "$status")
  if [ -n "$expected_signal" ]; then
    expected_name=$(signal_name_of "$expected_signal")
    [ -n "$expected_name" ] || expected_name=unknown
    expected_basis=exit-status-convention
  else
    expected_signal=none
    expected_name=none
    expected_basis=none
  fi
  if [ "$signal" != "$expected_signal" ] || [ "$name" != "$expected_name" ] || [ "$basis" != "$expected_basis" ]; then
    printf 'unreadable\tagent exit record unreadable (derived termination fields conflict with status %s)\n' "$status"
    return 0
  fi
  signal=$expected_signal
  name=$expected_name
  if [ "$disposition" = clean ]; then
    detail="agent exited cleanly (status 0)"
  else
    if [ "$signal" != none ] && [ -n "$signal" ]; then
      detail="agent exited on signal $signal"
      case "$name" in ''|none|unknown) ;; *) detail="$detail (SIG$name)" ;; esac
      detail="$detail, from status $status"
    else
      detail="agent exited with status $status"
    fi
  fi
  case "$utc" in ''|unknown) ;; *) detail="$detail at $utc" ;; esac
  if [ "$disposition" != clean ]; then
    pressure=$(pressure_clause "$path" exit)
    [ -n "$pressure" ] && detail="$detail; $pressure"
  fi
  if [ "$disposition" = clean ]; then
    printf 'recorded-clean\t%s\n' "$detail"
  else
    printf 'recorded-abnormal\t%s\n' "$detail"
  fi
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  arm)
    [ "$#" -eq 3 ] || die "usage: fm-exit-record.sh arm <state-dir> <id>"
    cmd_arm "$2" "$3"
    ;;
  record)
    [ "$#" -eq 4 ] || die "usage: fm-exit-record.sh record <state-dir> <id> <exit-status>"
    cmd_record "$2" "$3" "$4"
    ;;
  retire)
    [ "$#" -eq 3 ] || die "usage: fm-exit-record.sh retire <state-dir> <id>"
    cmd_retire "$2" "$3"
    ;;
  show)
    [ "$#" -eq 3 ] || die "usage: fm-exit-record.sh show <state-dir> <id>"
    cmd_show "$2" "$3"
    ;;
  *) usage; exit 2 ;;
esac
