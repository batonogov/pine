#!/bin/sh

set -eu

scenario="${1:-}"

case "$scenario" in
  working)
    printf '%s\n' '{"schemaVersion":1,"scenario":"working","events":[{"state":"started","pid":4100,"generation":1},{"state":"working","pid":4100,"generation":1}]}'
    ;;
  waiting)
    printf '%s\n' '{"schemaVersion":1,"scenario":"waiting","events":[{"state":"started","pid":4100,"generation":1},{"state":"waiting","pid":4100,"generation":1}]}'
    ;;
  completion)
    printf '%s\n' '{"schemaVersion":1,"scenario":"completion","events":[{"state":"started","pid":4100,"generation":1},{"state":"completed","pid":4100,"generation":1}]}'
    ;;
  failure)
    printf '%s\n' '{"schemaVersion":1,"scenario":"failure","events":[{"state":"started","pid":4100,"generation":1},{"state":"failed","pid":4100,"generation":1}]}'
    exit 17
    ;;
  malformed)
    printf '%s\n' '{not-json'
    ;;
  delayed)
    sleep 0.05
    printf '%s\n' '{"schemaVersion":1,"scenario":"delayed","events":[{"state":"started","pid":4100,"generation":1},{"state":"working","pid":4100,"generation":1}]}'
    ;;
  pid-reuse)
    printf '%s\n' '{"schemaVersion":1,"scenario":"pid-reuse","events":[{"state":"started","pid":4100,"generation":1},{"state":"replaced","pid":4100,"generation":2}]}'
    ;;
  process-replacement)
    printf '%s\n' '{"schemaVersion":1,"scenario":"process-replacement","events":[{"state":"started","pid":4100,"generation":1},{"state":"replaced","pid":4200,"generation":2}]}'
    ;;
  *)
    printf '%s\n' 'unsupported fake-agent scenario' >&2
    exit 64
    ;;
esac
