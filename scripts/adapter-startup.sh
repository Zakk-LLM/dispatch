# Shared adapter startup, before changing the workspace directory.
absolute_path() { realpath -m -- "$1"; }
RUN_DIR=$(absolute_path "$RUN_DIR") || exit 2
CWD=$(absolute_path "$CWD") || exit 2
[ -z "$PROMPT_FILE" ] || PROMPT_FILE=$(absolute_path "$PROMPT_FILE") || exit 2
[ -z "$SCHEMA" ] || SCHEMA=$(absolute_path "$SCHEMA") || exit 2
for index in "${!ADD_DIRS[@]}"; do
  ADD_DIRS[$index]=$(absolute_path "${ADD_DIRS[$index]}") || exit 2
done
case "$TIMEOUT" in *[!0-9]*|"") echo "bad --timeout: $TIMEOUT" >&2; exit 2 ;; esac
[ "$TIMEOUT" -gt 0 ] && [ "$TIMEOUT" -le 5400 ] || {
  echo "--timeout must be between 1 and 5400 seconds" >&2; exit 2;
}
RECOVERY_ARGS=()
[ "$RECOVERY" = 1 ] || RECOVERY_ARGS+=(--no-recovery)
# Sourced machine-local values need not have been exported by the user's config.
export AGENT_FALLBACK_PAIRS="${AGENT_FALLBACK_PAIRS:-}"
export AGENT_RECOVERY_ATTEMPTS="${AGENT_RECOVERY_ATTEMPTS:-${AGENT_LOCK_RETRIES:-4}}"
export AGENT_RECOVERY_BACKOFF="${AGENT_RECOVERY_BACKOFF:-2}"
