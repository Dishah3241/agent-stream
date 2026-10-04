#!/usr/bin/env bash
# agent-state.sh: structured run state derived from the activity protocol.
#
#   agent_state_track RUN_DIR [SEED_JSON]  < protocol lines
#       Writes RUN_DIR/state.json atomically whenever the state changes and
#       once more at EOF. Never prints anything on stdout.
#   agent_state_build [SEED_JSON]          < display.txt  > state.json
#       Prints the final state for a finished display file.
#   agent_state_finish RUN_DIR WORKER_EXIT CAPTURE_WORD
#       Merges the worker's exit status into RUN_DIR/state.json, decides the
#       outcome, and prints the "[end] ..." protocol line for display.txt.
#
# The state machine is lib/agent-state.jq; this file only moves bytes. The
# state is derived from display.txt lines, so it can always be rebuilt from
# the record. Bash 3.2 compatible; needs jq.

_AGENT_STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _agent_state_seed SEED: echo SEED when it is a JSON object, else {}.
_agent_state_seed() {
  local seed="${1:-}"
  if [[ -n "$seed" ]] && printf '%s' "$seed" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$seed"
  else
    printf '{}'
  fi
}

# _agent_state_write RUN_DIR: read snapshots on stdin, land each one as
# RUN_DIR/state.json via tmp + mv. A failed write is retried on the next
# snapshot; nothing here can fail the pipeline that feeds it.
_agent_state_write() {
  local dir="$1" snap
  while IFS= read -r snap; do
    [[ -n "$snap" ]] || continue
    if printf '%s\n' "$snap" >"$dir/state.json.tmp" 2>/dev/null; then
      mv -f "$dir/state.json.tmp" "$dir/state.json" 2>/dev/null || :
    fi
  done
  return 0
}

agent_state_track() {
  local dir="${1:-}" seed
  [[ -n "$dir" && -d "$dir" ]] || { cat >/dev/null; return 1; }
  seed="$(_agent_state_seed "${2:-}")"
  # jq holds the state; if it ever dies, cat drains stdin so the tee that
  # feeds this branch never sees a broken pipe.
  { jq -Rn --unbuffered -c --argjson seed "$seed" --argjson live true \
      -f "$_AGENT_STATE_DIR/agent-state.jq" 2>>"$dir/state.stderr" || cat >/dev/null; } \
    | _agent_state_write "$dir"
  return 0
}

agent_state_build() {
  local seed
  seed="$(_agent_state_seed "${1:-}")"
  jq -Rn -c --argjson seed "$seed" --argjson live false \
    -f "$_AGENT_STATE_DIR/agent-state.jq"
}

# agent_state_outcome WORKER_EXIT RESULT_KIND: the one word that names how
# the run ended. A zero exit with an error result is an error, never a
# success; a nonzero exit is a failure whatever the harness said.
agent_state_outcome() {
  local status="$1" kind="${2:-}"
  if [[ "$status" != 0 ]]; then
    printf 'failed'
  elif [[ "$kind" == "error" ]]; then
    printf 'error'
  elif [[ "$kind" == "cancelled" ]]; then
    printf 'cancelled'
  elif [[ "$kind" == "success" ]]; then
    printf 'success'
  else
    printf 'exited'
  fi
}

agent_state_finish() {
  local dir="$1" status="$2" capture_word="${3:-unknown}" kind="" el="" word
  [[ -n "$dir" && -d "$dir" ]] || return 1
  if [[ ! -s "$dir/state.json" && -f "$dir/display.txt" ]]; then
    agent_state_build <"$dir/display.txt" >"$dir/state.json.tmp" 2>/dev/null \
      && mv -f "$dir/state.json.tmp" "$dir/state.json"
  fi
  if [[ -s "$dir/state.json" ]]; then
    kind="$(jq -r '.result.kind // ""' "$dir/state.json" 2>/dev/null)" || kind=""
    el="$(jq -r '((now - ((.started_at | fromdate?) // now)) | floor | tostring)' "$dir/state.json" 2>/dev/null)" || el=""
  fi
  case "$el" in ''|*[!0-9]*) el=0 ;; esac
  word="$(agent_state_outcome "$status" "$kind")"
  if [[ -s "$dir/state.json" ]]; then
    jq -c --arg word "$word" --arg exit "$status" --arg cap "$capture_word" --arg el "$el" '
      .status = "ended"
      | .ended_at = (now | todate) | .updated_at = .ended_at
      | .elapsed_s = ($el | tonumber)
      | .waiting = null
      | .outcome = ((.outcome // {}) + {kind: $word, exit: ($exit | tonumber), capture: $cap,
                                        detail: ((.outcome // {}).detail // (.result // {}).detail // null)})
    ' "$dir/state.json" >"$dir/state.json.tmp" 2>/dev/null \
      && mv -f "$dir/state.json.tmp" "$dir/state.json"
  fi
  printf '[end] %s exit %s elapsed %ss record %s\n' "$word" "$status" "$el" "$dir"
}
