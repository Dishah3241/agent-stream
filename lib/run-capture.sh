#!/usr/bin/env bash
# run-capture.sh: generated run.sh sources this to capture a worker.
# Independent markers: worker exit, raw/capture, events, render, terminal,
# state. Missing markers are failures, never default-success. Bash 3.2.
#
# Pipeline for JSON formats (text differs only in what the raw file is):
#
#   worker stdout -> tee events.jsonl -> agent_output_render
#                 -> tee display.txt state.fifo -> live sink -> pane
#                                      state.fifo -> agent_state_track -> state.json
#
# Record completeness does not depend on anyone watching: the live sink is
# followed by a drain, the display tee ignores SIGPIPE, and the state
# tracker drains its own input if jq ever dies, so a closed pane or a dead
# tracker produces EOF, never a truncated display.txt or events.jsonl.
#
# After the worker exits the state is finalized with the exit status, one
# "[end] ..." line is appended to display.txt, and the ending card is
# printed for the pane.

run_capture_write_marker() {
  local dest="$1" value="$2"
  printf '%s\n' "$value" >"$dest.tmp" && mv -f "$dest.tmp" "$dest"
}

# Print a marker's status, or 1 when the file is missing, unreadable, or
# not an exit status. Absence is never treated as success.
run_capture_load_marker() {
  local path="$1" raw
  if [[ -L "$path" || ! -f "$path" || ! -r "$path" ]]; then
    printf '%s\n' 1
    return 0
  fi
  raw="$(cat "$path" 2>/dev/null)" || raw=""
  if [[ "$raw" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( raw <= 255 )); then
    printf '%s\n' "$raw"
  else
    printf '%s\n' 1
  fi
}

run_capture_live_sink() {
  if [[ -f "${lib:-}/agent-present.sh" ]]; then
    # shellcheck source=/dev/null
    . "$lib/agent-present.sh"
    agent_present_stream
    local stream_status=$?
    if [[ "${_AP_STREAM_HAD_OUTPUT:-0}" == 1 && "${_AP_STREAM_TRAILING_NEWLINE:-1}" == 0 ]]; then
      printf '\n' || stream_status=1
    fi
    return "$stream_status"
  else
    cat
  fi
}

# The pane is the last stage and the one most likely to go away. Run the
# sink in a subshell so a SIGPIPE kills only it, then drain to EOF so the
# tee upstream never sees a broken pipe. The sink's status is still the
# terminal marker.
run_capture_live_sink_guard() {
  local rc
  ( run_capture_live_sink )
  rc=$?
  run_capture_drain
  return "$rc"
}

# tee -p (GNU) keeps writing the other outputs after a pipe fails; BSD tee
# does that by default once SIGPIPE is ignored. Probe once.
run_capture_tee_flag() {
  if [[ -z "${_RC_TEE_PROBED:-}" ]]; then
    _RC_TEE_PROBED=1
    _RC_TEE_P=""
    if tee -p </dev/null >/dev/null 2>&1; then _RC_TEE_P="-p"; fi
  fi
  printf '%s' "$_RC_TEE_P"
}

# Display tee: display.txt plus the state fifo, immune to a reader that
# goes away. Its stderr lands in the record, not in the pane.
run_capture_display_tee() {
  local flag
  flag="$(run_capture_tee_flag)"
  trap '' PIPE
  if [[ -n "$flag" ]]; then
    exec tee "$flag" "$run/display.txt" "$run/state.fifo" 2>>"$run/display-tee.stderr"
  else
    exec tee "$run/display.txt" "$run/state.fifo" 2>>"$run/display-tee.stderr"
  fi
}

run_capture_is_json_format() {
  case "$1" in
    pi-json|claude-json|cursor-json|grok-json|acp-json) return 0 ;;
    *) return 1 ;;
  esac
}

run_capture_agent_for_format() {
  case "$1" in
    pi-json) printf 'pi' ;;
    claude-json) printf 'claude' ;;
    cursor-json) printf 'cursor' ;;
    grok-json) printf 'grok' ;;
    acp-json) printf 'acp' ;;
    *) printf '' ;;
  esac
}

# Unlink leftover FIFO names. Does not wait: a wait here can deadlock
# if a consumer is still opening. Children must not inherit a write end.
run_capture_fifo_release() {
  [[ -n "${run:-}" ]] || return 0
  rm -f "$run/stdout.fifo" "$run/stderr.fifo" "$run/state.fifo"
}

# Drain remaining stdin so an upstream exclusive writer is never stuck
# behind a failed renderer, display tee, or live sink.
run_capture_drain() {
  cat >/dev/null
}

# One plain line so a watcher of log.txt sees where the live render is.
# The JSON path overwrites this file with events plus stderr after exit.
run_capture_log_stub() {
  printf '%s\n' "agent-run: streaming to ${run}/display.txt; log.txt is rewritten when the worker exits" >"$run/log.txt"
}

# Prefix each stderr line for the presenter. Raw bytes stay in stderr.txt.
run_capture_note_stderr() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '[note] %s\n' "$line"
  done
}

# ------------------------------------------------------------- context --
# run_capture_context FORMAT: the merged input contract as one JSON object
# on stdout. The caller's header.json (when it is one JSON object) wins;
# what it leaves out is detected: project from the git top-level directory
# name (else the directory name), branch from git, agent from the format,
# id from the record directory name, task from label or brief.md. The file
# on disk is never rewritten.
run_capture_context() {
  local format="$1" header='{}' cwd project branch task id agent top
  if [[ -f "${run:-}/header.json" && ! -L "$run/header.json" ]] \
     && jq -e 'type == "object"' "$run/header.json" >/dev/null 2>&1; then
    header="$(cat "$run/header.json")"
  fi
  cwd="$(printf '%s' "$header" | jq -r '.cwd // "" | if type == "string" then . else "" end' 2>/dev/null)"
  if [[ -z "$cwd" || ! -d "$cwd" ]]; then cwd="$PWD"; fi
  project="$(printf '%s' "$header" | jq -r '.project // "" | if type == "string" then . else "" end' 2>/dev/null)"
  if [[ -z "$project" ]]; then
    top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || top=""
    project="$(basename "${top:-$cwd}")"
  fi
  branch="$(printf '%s' "$header" | jq -r '.branch // "" | if type == "string" then . else "" end' 2>/dev/null)"
  if [[ -z "$branch" ]]; then
    branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch=""
    if [[ "$branch" == "HEAD" ]]; then
      branch="detached $(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)"
    fi
  fi
  task="$(printf '%s' "$header" | jq -r '.task // .label // "" | if type == "string" then . else "" end' 2>/dev/null)"
  if [[ -z "$task" && -f "$run/brief.md" && ! -L "$run/brief.md" ]]; then
    task="$(cat "$run/brief.md" 2>/dev/null)"
  fi
  id="$(printf '%s' "$header" | jq -r '.id // "" | if type == "string" then . else "" end' 2>/dev/null)"
  [[ -n "$id" ]] || id="$(basename "$run")"
  agent="$(printf '%s' "$header" | jq -r '.agent // "" | if type == "string" then . else "" end' 2>/dev/null)"
  [[ -n "$agent" ]] || agent="$(run_capture_agent_for_format "$format")"
  printf '%s' "$header" | jq -c \
    --arg id "$id" --arg agent "$agent" --arg cwd "$cwd" --arg dir "$run" \
    --arg project "$project" --arg branch "$branch" --arg task "$task" '
    . + {id: $id, agent: (if $agent == "" then (.agent // null) else $agent end),
         cwd: $cwd, dir: (.dir // $dir), project: $project,
         branch: (if $branch == "" then null else $branch end),
         task: (if $task == "" then null else $task end)}' 2>/dev/null \
    || printf '{"id":"%s","dir":"%s"}' "$id" "$run"
}

# The seed for state.json, derived from the merged context.
run_capture_state_seed() {
  local theme loud
  theme="$(run_capture_theme_choice "$1")"
  loud="${theme#*$'\t'}"
  theme="${theme%%$'\t'*}"
  printf '%s' "$1" | jq -c --arg dir "$run" --arg theme "$theme" --arg loud "$loud" '
    {id: .id, agent: .agent, model_requested: (.model_requested // null),
     task: .task,
     parent: (.parent // null | if type == "string" then . else null end),
     project: {name: .project, dir: .cwd, branch: .branch},
     theme: {name: $theme, loudness: $loud},
     record: {dir: $dir, events: ($dir + "/events.jsonl"), display: ($dir + "/display.txt"),
              state: ($dir + "/state.json"), log: ($dir + "/log.txt")}}' 2>/dev/null \
    || printf '{}'
}

# run_capture_theme_choice CONTEXT: "THEME<TAB>LOUDNESS" the run asked for:
# the environment, else the project's .agent-stream/config.json, else space
# at loud. Recorded in state.json so a watcher or board on another machine
# styles the run the way its own project chose; what this terminal can
# show is decided later, by the presenter.
run_capture_theme_choice() {
  local cwd top cfg theme="${AGENT_STREAM_THEME:-}" loud="${AGENT_STREAM_LOUDNESS:-}"
  cwd="$(printf '%s' "$1" | jq -r '.cwd // ""' 2>/dev/null)" || cwd=""
  if [[ -n "$cwd" ]] && command -v git >/dev/null 2>&1; then
    top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || top=""
    if [[ -n "$top" && -f "$top/.agent-stream/config.json" ]]; then
      cfg="$(jq -r '[(.theme // "" | tostring), (.loudness // "" | tostring)] | @tsv' \
        "$top/.agent-stream/config.json" 2>/dev/null)" || cfg=""
      [[ -n "$theme" ]] || theme="${cfg%%$'\t'*}"
      [[ -n "$loud" ]] || loud="${cfg#*$'\t'}"
    fi
  fi
  case "$theme" in ''|auto) theme=space ;; esac
  printf '%s\t%s' "$theme" "${loud:-loud}"
}

# The header is printed only when the caller wrote one: a dispatcher that
# prints its own header does not get a second one. The merged context is
# what it shows. Printed from a subshell that ignores SIGPIPE, so a pane
# that is already gone cannot kill the caller.
run_capture_header() {
  if [[ -f "${lib:-}/agent-present.sh" && -f "${run:-}/header.json" ]]; then
    (
      trap '' PIPE
      # shellcheck source=/dev/null
      . "$lib/agent-present.sh"
      printf '%s' "$_RC_CONTEXT" | agent_present_header
    ) 2>/dev/null || true
  fi
}

# The ending card, from the finalized state. Falls back to the plain
# "[end]" line when the presenter is not available. Same SIGPIPE guard:
# the record is already complete by now, the pane is best effort.
run_capture_ending() {
  (
    trap '' PIPE
    if [[ -f "${lib:-}/agent-present.sh" && -s "${run:-}/state.json" ]]; then
      # shellcheck source=/dev/null
      . "$lib/agent-present.sh"
      agent_present_end <"$run/state.json" && exit 0
    fi
    printf '%s\n' "$1"
  ) 2>/dev/null || true
}

# run_capture_finish WORKER_STATUS CAPTURE_STATUS: finalize state.json,
# append the [end] line to display.txt, print the ending for the pane.
run_capture_finish() {
  local status="$1" capture="$2" word end_line
  if [[ "$capture" == 0 ]]; then word=complete; else word="failed"; fi
  end_line=""
  if [[ -f "${lib:-}/agent-state.sh" ]]; then
    # shellcheck source=/dev/null
    . "$lib/agent-state.sh"
    end_line="$(agent_state_finish "$run" "$status" "$word")" || end_line=""
  fi
  if [[ -z "$end_line" ]]; then
    end_line="[end] exited exit $status record $run"
  fi
  printf '%s\n' "$end_line" >>"$run/display.txt" 2>/dev/null || :
  run_capture_ending "$end_line"
}

# Start the state tracker on the state fifo. It must be reading before
# the display tee opens the fifo for writing. Without the state library
# the fifo still needs a reader, so a drain takes its place.
run_capture_state_start() {
  (
    set +e
    if [[ -f "${lib:-}/agent-state.sh" ]]; then
      # shellcheck source=/dev/null
      . "$lib/agent-state.sh"
      agent_state_track "$run" "$_RC_SEED" <"$run/state.fifo"
      run_capture_write_marker "$run/state" $?
    else
      run_capture_drain <"$run/state.fifo"
      run_capture_write_marker "$run/state" 1
    fi
  ) &
  _RC_STATE_PID=$!
}

# Drop a trailing copy of last-message.txt from the live text stream when
# that same text was already printed. Bytes already written to log.txt
# are upstream of this filter and stay unchanged.
run_capture_dedupe_stream() {
  local msg="$run/last-message.txt"
  if ! command -v python3 >/dev/null 2>&1; then
    cat
    return 0
  fi
  python3 -c "$(cat <<'PY'
import sys
path = sys.argv[1]
written = []

def message():
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    if not data:
        return None
    if data.endswith(b"\n"):
        data = data[:-1]
    return data.decode("utf-8", "replace").split("\n")

def emit(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()
    written.append(line)
    if len(written) > 400:
        del written[:-400]

def already(msg):
    if not msg:
        return False
    return "\n".join(msg) in "\n".join(written)

buf = []
for raw in sys.stdin:
    line = raw[:-1] if raw.endswith("\n") else raw
    msg = message()
    if not msg:
        emit(line)
        continue
    buf.append(line)
    while len(buf) > len(msg):
        emit(buf.pop(0))
msg = message()
if msg and buf == msg and already(msg):
    raise SystemExit(0)
for line in buf:
    emit(line)
PY
)" "$msg"
}

# run_capture_exec FORMAT -- argv...
# Uses $run (record dir) and $lib (libraries). Sets $status and $capture.
run_capture_exec() {
  local format="$1" out_pid="" err_pid="" logst=1 task
  local events=1 render=1 terminal=1 errtee=1
  shift
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  [[ -n "${run:-}" ]] || return 1
  touch "$run/log.txt" "$run/display.txt"
  _RC_CONTEXT="$(run_capture_context "$format")"
  _RC_SEED="$(run_capture_state_seed "$_RC_CONTEXT")"
  # The pane picks its theme from the run's project, not from wherever the
  # dispatcher happens to be. Local, so the caller's environment is unchanged;
  # the presenter's subshells see it through dynamic scope.
  local AGENT_STREAM_PROJECT_DIR="${AGENT_STREAM_PROJECT_DIR:-$(printf '%s' "$_RC_CONTEXT" | jq -r '.cwd // ""' 2>/dev/null)}"
  _RC_STATE_PID=""
  task="$(printf '%s' "$_RC_CONTEXT" | jq -r '.task // ""' 2>/dev/null)"
  if [[ -n "$task" ]]; then
    printf '%s\n' "$task" >"$run/task.txt" 2>/dev/null || :
  fi
  run_capture_header

  if run_capture_is_json_format "$format"; then
    rm -f "$run/stdout.fifo" "$run/stderr.fifo" "$run/state.fifo"
    mkfifo "$run/stdout.fifo" "$run/stderr.fifo" "$run/state.fifo" || {
      status=97
      capture=1
      run_capture_write_marker "$run/startup" "could not create capture fifos"
      return 0
    }
    : >"$run/events.jsonl"
    : >"$run/events-tee.stderr"
    : >"$run/stderr.txt"
    run_capture_log_stub
    # Readers first, then the worker. Opening a FIFO for write blocks
    # until a reader exists, so start order avoids a silent drop. Do not
    # hold an extra RDWR end in this shell: children would inherit it and
    # never see EOF after the worker exits.
    trap 'run_capture_fifo_release' EXIT
    run_capture_state_start

    (
      set +e
      # Exclusive events writer. Presentation lives on the right of this
      # tee and must drain on failure so SIGPIPE cannot rewrite capture.
      tee "$run/events.jsonl" <"$run/stdout.fifo" 2>"$run/events-tee.stderr" | {
        if [[ -f "${lib:-}/agent-output.sh" ]]; then
          # shellcheck source=/dev/null
          . "$lib/agent-output.sh"
          agent_output_render "$format" \
            | ( run_capture_display_tee ) \
            | run_capture_live_sink_guard
          evs=("${PIPESTATUS[@]}")
          run_capture_write_marker "$run/render" "${evs[0]:-1}"
          run_capture_write_marker "$run/display-write" "${evs[1]:-1}"
          run_capture_write_marker "$run/terminal" "${evs[2]:-1}"
        else
          # No renderer: keep the clean event bytes, do not flood the pane.
          run_capture_write_marker "$run/render" 1
          run_capture_write_marker "$run/terminal" 1
          : >"$run/state.fifo"
        fi
        run_capture_drain
      }
      evs=("${PIPESTATUS[@]}")
      run_capture_write_marker "$run/events" "${evs[0]:-1}"
    ) &
    out_pid=$!

    (
      set +e
      # Raw stderr stays in the file. The pane sees presenter [note] lines.
      tee "$run/stderr.txt" <"$run/stderr.fifo" | {
        run_capture_note_stderr | run_capture_live_sink_guard
        run_capture_drain
      }
      evs=("${PIPESTATUS[@]}")
      run_capture_write_marker "$run/errtee" "${evs[0]:-1}"
    ) &
    err_pid=$!

    ( exec "$@" ) </dev/null >"$run/stdout.fifo" 2>"$run/stderr.fifo"
    status=$?

    trap - EXIT
    wait "$out_pid" 2>/dev/null || true
    wait "$err_pid" 2>/dev/null || true
    [[ -z "$_RC_STATE_PID" ]] || wait "$_RC_STATE_PID" 2>/dev/null || true
    rm -f "$run/stdout.fifo" "$run/stderr.fifo" "$run/state.fifo"

    # Rebuild log.txt after both exclusive writers finish so raw bytes are
    # not interleaved by concurrent appends. Write in place so an
    # unwritable log.txt is a capture failure, not a silent replace.
    if { cat "$run/events.jsonl"; cat "$run/stderr.txt"; } >"$run/log.txt"; then
      logst=0
    else
      logst=1
    fi

    events="$(run_capture_load_marker "$run/events")"
    render="$(run_capture_load_marker "$run/render")"
    terminal="$(run_capture_load_marker "$run/terminal")"
    errtee="$(run_capture_load_marker "$run/errtee")"
    capture=0
    [[ "$events" == 0 ]] || capture="$events"
    [[ "$errtee" == 0 ]] || capture="$errtee"
    [[ "$logst" == 0 ]] || capture="$logst"
    # Keep render/terminal independent: never copy them onto capture or status.
    : "$render" "$terminal"
  else
    # Native text (Codex/OpenCode): raw bytes stay in log.txt.
    # Display is sanitized through the text renderer so CSI never lands
    # in saved --output/--follow. Live sink is independent of capture.
    set +e
    rm -f "$run/state.fifo"
    if mkfifo "$run/state.fifo" 2>/dev/null; then
      trap 'run_capture_fifo_release' EXIT
      run_capture_state_start
    fi
    ( exec "$@" ) </dev/null 2>&1 \
      | tee "$run/log.txt" \
      | {
          if [[ -f "${lib:-}/agent-output.sh" ]]; then
            # shellcheck source=/dev/null
            . "$lib/agent-output.sh"
            if [[ -p "$run/state.fifo" ]]; then
              agent_output_render text \
                | run_capture_dedupe_stream \
                | ( run_capture_display_tee ) \
                | run_capture_live_sink_guard
            else
              agent_output_render text \
                | run_capture_dedupe_stream \
                | tee "$run/display.txt" \
                | run_capture_live_sink_guard
            fi
            evs=("${PIPESTATUS[@]}")
            run_capture_write_marker "$run/render" "${evs[0]:-1}"
            run_capture_write_marker "$run/display-write" "${evs[2]:-1}"
            run_capture_write_marker "$run/terminal" "${evs[3]:-1}"
          else
            tee "$run/display.txt" | run_capture_live_sink_guard
            evs=("${PIPESTATUS[@]}")
            run_capture_write_marker "$run/render" 1
            run_capture_write_marker "$run/display-write" "${evs[0]:-1}"
            run_capture_write_marker "$run/terminal" "${evs[1]:-1}"
            [[ ! -p "$run/state.fifo" ]] || : >"$run/state.fifo"
          fi
          run_capture_drain
        }
    evs=("${PIPESTATUS[@]}")
    status="${evs[0]:-1}"
    capture="${evs[1]:-1}"
    trap - EXIT
    [[ -z "$_RC_STATE_PID" ]] || wait "$_RC_STATE_PID" 2>/dev/null || true
    rm -f "$run/state.fifo"
  fi
  run_capture_finish "$status" "$capture"
}
