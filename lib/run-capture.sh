#!/usr/bin/env bash
# run-capture.sh: generated run.sh sources this to capture a worker.
# Independent markers: worker exit, raw/capture, events, render, terminal.
# Missing markers are failures, never default-success. Bash 3.2.

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

run_capture_header() {
  if [[ -f "${lib:-}/agent-present.sh" && -f "${run:-}/header.json" ]]; then
    # shellcheck source=/dev/null
    . "$lib/agent-present.sh"
    agent_present_header <"$run/header.json" || true
  fi
}

run_capture_is_json_format() {
  case "$1" in
    pi-json|claude-json|cursor-json|grok-json) return 0 ;;
    *) return 1 ;;
  esac
}

# Unlink leftover FIFO names. Does not wait: a wait here can deadlock
# if a consumer is still opening. Children must not inherit a write end.
run_capture_fifo_release() {
  [[ -n "${run:-}" ]] || return 0
  rm -f "$run/stdout.fifo" "$run/stderr.fifo"
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
  local format="$1" out_pid="" err_pid="" logst=1
  local events=1 render=1 terminal=1 errtee=1
  shift
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  [[ -n "${run:-}" ]] || return 1
  touch "$run/log.txt" "$run/display.txt"
  run_capture_header

  if run_capture_is_json_format "$format"; then
    rm -f "$run/stdout.fifo" "$run/stderr.fifo"
    mkfifo "$run/stdout.fifo" "$run/stderr.fifo" || {
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

    (
      set +e
      # Exclusive events writer. Presentation lives on the right of this
      # tee and must drain on failure so SIGPIPE cannot rewrite capture.
      tee "$run/events.jsonl" <"$run/stdout.fifo" 2>"$run/events-tee.stderr" | {
        if [[ -f "${lib:-}/agent-output.sh" ]]; then
          # shellcheck source=/dev/null
          . "$lib/agent-output.sh"
          agent_output_render "$format" \
            | tee "$run/display.txt" \
            | run_capture_live_sink
          evs=("${PIPESTATUS[@]}")
          run_capture_write_marker "$run/render" "${evs[0]:-1}"
          run_capture_write_marker "$run/display-write" "${evs[1]:-1}"
          run_capture_write_marker "$run/terminal" "${evs[2]:-1}"
        else
          # No renderer: keep the clean event bytes, do not flood the pane.
          run_capture_write_marker "$run/render" 1
          run_capture_write_marker "$run/terminal" 1
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
        run_capture_note_stderr | run_capture_live_sink
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
    rm -f "$run/stdout.fifo" "$run/stderr.fifo"

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
    ( exec "$@" ) </dev/null 2>&1 \
      | tee "$run/log.txt" \
      | {
          if [[ -f "${lib:-}/agent-output.sh" ]]; then
            # shellcheck source=/dev/null
            . "$lib/agent-output.sh"
            agent_output_render text \
              | run_capture_dedupe_stream \
              | tee "$run/display.txt" \
              | run_capture_live_sink
            evs=("${PIPESTATUS[@]}")
            run_capture_write_marker "$run/render" "${evs[0]:-1}"
            run_capture_write_marker "$run/display-write" "${evs[2]:-1}"
            run_capture_write_marker "$run/terminal" "${evs[3]:-1}"
          else
            tee "$run/display.txt" | run_capture_live_sink
            evs=("${PIPESTATUS[@]}")
            run_capture_write_marker "$run/render" 1
            run_capture_write_marker "$run/display-write" "${evs[0]:-1}"
            run_capture_write_marker "$run/terminal" "${evs[1]:-1}"
          fi
          run_capture_drain
        }
    evs=("${PIPESTATUS[@]}")
    status="${evs[0]:-1}"
    capture="${evs[1]:-1}"
  fi
}
