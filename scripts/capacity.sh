#!/usr/bin/env bash
# Suggest how many agents of a given weight this machine can run at once. Nothing here is a
# fixed constant: the answer follows the current cores, free memory, and what the agents do.
set -euo pipefail

# Machine-local defaults (tier-to-model bindings, the shared cap) live outside this repository
# so nothing here assumes a provider's lineup. The file is optional.
ENV_FILE=${AGENT_ORCHESTRATION_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-orchestration.env}
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

usage() {
  cat <<'EOF'
Usage: capacity.sh --engine omp|codex|opencode [light|medium|heavy] [--per-agent-mb N]

  light   read-only reading, search, drafting            (~400 MB/agent)
  medium  edits plus a test file or a linter run         (~1200 MB/agent)
  heavy   full builds, whole test suites, containers     (~4000 MB/agent)

Prints the suggested concurrency and the numbers it came from. Override the memory estimate
with --per-agent-mb when you know what the workload actually costs.

OMP uses OMP_MAX_AGENTS and counts OMP agents. Codex and OpenCode use AGENT_MAX_AGENTS
and count both metered engines in their shared pool.
EOF
}

ENGINE=; WEIGHT=medium; PER=
while [ $# -gt 0 ]; do
  case "$1" in
    --engine) [ $# -ge 2 ] || { echo "missing engine after --engine" >&2; exit 2; }
      ENGINE=$2; shift 2 ;;
    --per-agent-mb) [ $# -ge 2 ] || { echo "--per-agent-mb needs a value" >&2; exit 2; }
      PER=$2; shift 2 ;;
    light|medium|heavy) WEIGHT=$1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$ENGINE" ] || { echo "--engine is required" >&2; usage >&2; exit 2; }
case "$ENGINE" in omp|codex|opencode) ;; *) echo "unsupported engine: $ENGINE" >&2; exit 2 ;; esac
case "$WEIGHT" in
  light) DEFAULT_PER=400; CPU_DIV=1 ;;
  medium) DEFAULT_PER=1200; CPU_DIV=2 ;;
  heavy) DEFAULT_PER=4000; CPU_DIV=4 ;;
esac
[ -n "$PER" ] || PER=$DEFAULT_PER

# agents.sh owns process identity, zombie filtering, and wrapper-child de-duplication. Pool
# selection stays here because OMP has an independent cap while Codex and OpenCode share one;
# load, CPU, and memory limits below apply to every engine.
AGENTS="$(cd "$(dirname "$0")" && pwd)/agents.sh"
case "$ENGINE" in
  omp)
    RUNNING=$("$AGENTS" --count --engine omp 2>/dev/null)
    GLOBAL_MAX=${OMP_MAX_AGENTS:-5}
    QUOTA_NAME=OMP_MAX_AGENTS
    ;;
  codex|opencode)
    CODEX_RUNNING=$("$AGENTS" --count --engine codex 2>/dev/null)
    OPENCODE_RUNNING=$("$AGENTS" --count --engine opencode 2>/dev/null)
    RUNNING=$(( ${CODEX_RUNNING:-0} + ${OPENCODE_RUNNING:-0} ))
    GLOBAL_MAX=${AGENT_MAX_AGENTS:-5}
    QUOTA_NAME=AGENT_MAX_AGENTS
    ;;
esac
RUNNING=${RUNNING:-0}
FREE=$(( GLOBAL_MAX - RUNNING ))
[ "$FREE" -lt 0 ] && FREE=0

CORES=$(nproc 2>/dev/null || echo 4)
AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 4096)
LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)

# Keep a core and 15% of free memory for the orchestrator, the editor, and the tests it runs.
BY_CPU=$(( (CORES - 1) / CPU_DIV ))
BY_MEM=$(( AVAIL_MB * 85 / 100 / PER ))
BUSY=$(awk -v l="$LOAD" -v c="$CORES" 'BEGIN {print (l > c * 0.7) ? 1 : 0}')

N=$BY_CPU
[ "$BY_MEM" -lt "$N" ] && N=$BY_MEM
[ "$BUSY" = 1 ] && N=$(( N / 2 ))
[ "$N" -lt 1 ] && N=1
# Beyond a handful a metered API just queues, so the default ceiling is small. An engine with
# no rate limit is bounded by the machine instead: raise AGENT_CONCURRENCY_CEILING for it.
# Note what this number is not: your review capacity. Thirty agents can run while only three
# can be reviewed properly, so a high ceiling belongs to uniform mechanical work whose review
# is batched, not to work that needs a diff read each.
CEILING=${AGENT_CONCURRENCY_CEILING:-8}
[ "$N" -gt "$CEILING" ] && N=$CEILING
# The global cap wins: it counts agents this session cannot see.
[ "$N" -gt "$FREE" ] && N=$FREE

printf '%s\n' "$N"
printf 'engine=%s weight=%s per-agent=%sMB cores=%s avail=%sMB load=%s cpu-cap=%s mem-cap=%s running=%s/%s free=%s%s\n' \
  "$ENGINE" "$WEIGHT" "$PER" "$CORES" "$AVAIL_MB" "$LOAD" "$BY_CPU" "$BY_MEM" "$RUNNING" "$GLOBAL_MAX" "$FREE" \
  "$([ "$BUSY" = 1 ] && echo ' (machine busy: halved)')" >&2
if [ "$N" = 0 ]; then
  printf 'no free slot: %s agents already running in the %s pool (%s=%s)\n' \
    "$RUNNING" "$ENGINE" "$QUOTA_NAME" "$GLOBAL_MAX" >&2
fi
exit 0
