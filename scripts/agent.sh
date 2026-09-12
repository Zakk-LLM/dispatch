#!/usr/bin/env bash
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ENGINE=${DISPATCH_ENGINE:-}
ARGS=()

while [ $# -gt 0 ]; do
  if [ "$1" = --engine ]; then
    [ $# -ge 2 ] || { echo "missing engine after --engine" >&2; exit 2; }
    ENGINE=$2
    shift 2
  else
    ARGS+=("$1")
    shift
  fi
done

[ -n "$ENGINE" ] || { echo "missing engine: set DISPATCH_ENGINE or pass --engine omp|codex|opencode" >&2; exit 2; }
case "$ENGINE" in
  omp|codex|opencode) exec "$HERE/engines/$ENGINE/agent.sh" "${ARGS[@]}" ;;
  *) echo "unsupported engine: $ENGINE" >&2; exit 2 ;;
esac
