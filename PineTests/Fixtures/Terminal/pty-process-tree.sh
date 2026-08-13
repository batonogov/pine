#!/bin/sh

# Deterministic, network-free PTY fixture for terminal lifecycle tests.
# The trace contains process identities and phases only. It deliberately never
# records terminal input/output, the environment, prompts, or credentials.

set -u

scenario="${1:-}"
trace_file="${2:-}"

if [ -z "$scenario" ] || [ -z "$trace_file" ]; then
  exit 64
fi

umask 077
: > "$trace_file"

record_phase() {
  phase="$1"
  process_id="$2"
  process_group=$(/bin/ps -o pgid= -p "$process_id" 2>/dev/null | /usr/bin/tr -d ' ')
  printf 'phase=%s pid=%s pgid=%s\n' \
    "$phase" "$process_id" "${process_group:-0}" >> "$trace_file"
}

announce_ready() {
  record_phase ready "$$"
  printf 'PINE_PTY_FIXTURE_READY:%s\n' "$scenario"
}

spawn_ignoring_child() {
  /bin/sh -c 'trap "" HUP INT TERM; while :; do /bin/sleep 1; done' &
  fixture_child=$!
  record_phase child "$fixture_child"
}

case "$scenario" in
  churn)
    # Monitor mode gives the child its own process group. Moving it into the
    # foreground exercises tcgetpgrp/PGID churn through SwiftTerm's real PTY.
    set -m
    /bin/sh -c 'trap "exit 0" HUP INT TERM; while :; do /bin/sleep 1; done' &
    fixture_child=$!
    record_phase foreground-child "$fixture_child"
    announce_ready
    fg %1 || true
    record_phase foreground-returned "$$"
    printf 'PINE_PTY_FIXTURE_FOREGROUND_RETURNED\n'
    while IFS= read -r command; do
      [ "$command" = "exit" ] && exit 0
    done
    ;;

  tree)
    set -m
    spawn_ignoring_child
    announce_ready
    while IFS= read -r command; do
      case "$command" in
        replace)
          /bin/kill -KILL "$fixture_child" 2>/dev/null || true
          wait "$fixture_child" 2>/dev/null || true
          record_phase replaced "$fixture_child"
          spawn_ignoring_child
          record_phase replacement "$fixture_child"
          printf 'PINE_PTY_FIXTURE_REPLACED\n'
          ;;
        exit-success)
          record_phase natural-success "$$"
          exit 0
          ;;
        exit-failure)
          record_phase natural-failure "$$"
          exit 17
          ;;
      esac
    done
    ;;

  stream)
    # Split both UTF-8 and ANSI control sequences across writes, then emit a
    # bounded burst large enough to exercise DispatchIO backpressure.
    line=0
    while [ "$line" -lt 4096 ]; do
      printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n'
      line=$((line + 1))
    done
    printf '\342'
    /bin/sleep 0.02
    printf '\234\223'
    printf '\033['
    /bin/sleep 0.02
    printf '32mSTREAM\033[0m\n'
    record_phase stream-complete "$$"
    printf 'PINE_PTY_FIXTURE_STREAM_COMPLETE\n'
    announce_ready
    while IFS= read -r command; do
      [ "$command" = "exit" ] && exit 0
    done
    ;;

  success)
    announce_ready
    exit 0
    ;;

  failure)
    announce_ready
    exit 17
    ;;

  *)
    record_phase unsupported "$$"
    exit 64
    ;;
esac
