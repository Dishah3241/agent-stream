#!/usr/bin/env bash
set -euo pipefail

# Bash 3.2 (macOS /bin/bash) does not apply errexit to a failing [[ ]], so
# every bare assertion below names the fallback explicitly.
fail() { echo "agent-output test: ${*:-assertion failed at line ${BASH_LINENO[0]}}" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LIB="$ROOT/lib/agent-output.sh"

# shellcheck source=../lib/agent-output.sh
source "$LIB"

# render FORMAT input... : run the renderer over fixture text, capture
# stdout, stderr, and the exit status without letting errexit fire.
render() {
  local format="$1"
  RENDER_OUT="$TMP/render.out"
  RENDER_ERR="$TMP/render.err"
  RENDER_RC=0
  printf '%s' "$2" | agent_output_render "$format" >"$RENDER_OUT" 2>"$RENDER_ERR" || RENDER_RC=$?
}

expect_rc() {
  local want="$1" got="$2" what="$3"
  if [[ "$got" != "$want" ]]; then
    fail "$what: expected exit $want, got $got (stderr: $(cat "$RENDER_ERR" 2>/dev/null))"
  fi
}

# ---------------------------------------------------------------- format gate

rc=0
agent_output_render teleports </dev/null >/dev/null 2>"$TMP/bad.err" || rc=$?
if [[ "$rc" -eq 0 ]]; then
  fail "unknown format must be rejected, got rc 0"
fi
grep -q 'pi-json' "$TMP/bad.err" || fail "rejection must name the supported formats"

rc=0
agent_output_render </dev/null >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  fail "missing format argument must exit nonzero, got $rc"
fi

# The space-separated list string is not itself a format.
rc=0
agent_output_render "$AGENT_OUTPUT_FORMATS" </dev/null >/dev/null 2>"$TMP/list.err" || rc=$?
if [[ "$rc" -eq 0 ]]; then
  fail "AGENT_OUTPUT_FORMATS as FORMAT must be rejected, got rc 0"
fi
grep -q 'unknown format' "$TMP/list.err" || fail "list-string rejection must say unknown format"

for format in pi-json claude-json cursor-json grok-json text; do
  printf '' | agent_output_render "$format" >/dev/null 2>&1 || {
    rc=$?
    fail "empty input must succeed for $format (rc $rc)"
  }
done

# Membership must not depend on the caller's IFS.
rc=0
( IFS='|'; printf '' | agent_output_render pi-json >/dev/null ) || rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "pi-json must be accepted even when IFS is not the default (rc $rc)"
fi

# ------------------------------------------------------------------ text mode

render text $'plain line\n\x1b[31mred\x1b[0m words\r\nbell \x07 here\ttab café ☕\n\nend\n'
expect_rc 0 "$RENDER_RC" "text mode exit"
if grep -q $'\x1b' "$RENDER_OUT"; then
  fail "text mode must strip terminal escapes"
fi
if grep -q $'\x07' "$RENDER_OUT" || grep -q $'\r' "$RENDER_OUT"; then
  fail "text mode must strip control characters"
fi
grep -q 'red words' "$RENDER_OUT" || fail "text mode must keep the visible words"
grep -q $'here\ttab café ☕' "$RENDER_OUT" || fail "text mode must keep tabs and Unicode"
if [[ "$(wc -l < "$RENDER_OUT")" -ne 5 ]]; then
  fail "text mode must preserve line breaks including blank lines, got $(wc -l < "$RENDER_OUT") lines"
fi
render text $'pongINFO Skill turn summary\n'
grep -qx 'pong' "$RENDER_OUT" || fail "glued INFO must break onto its own line"
grep -qx 'INFO Skill turn summary' "$RENDER_OUT" || fail "INFO prefix must stay intact"


# ------------------------------------------------------------------ pi-json

PI_STREAM='{"type":"session","version":3,"id":"6f2a1b3c-4d5e-4f60-a1b2-c3d4e5f60718","timestamp":"2026-09-20T10:00:00Z","cwd":"/tmp/proj"}
{"type":"agent_start"}
{"type":"turn_start"}
{"type":"message_start","message":{"role":"assistant","content":[]}}
{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"thinking_start","contentIndex":0}}
{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"SECRET-THINKING-PAYLOAD"}}
{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"The answer is "}}
{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"42.\n"}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"The answer is 42.\n"}],"stopReason":"stop"}}
{"type":"tool_execution_start","toolCallId":"t1","toolName":"read","args":{"path":"README.md"}}
{"type":"tool_execution_update","toolCallId":"t1","toolName":"read","args":{"path":"README.md"},"partialResult":"SECRET-PARTIAL-PAYLOAD"}
{"type":"tool_execution_end","toolCallId":"t1","toolName":"read","result":{"output":"file body here"},"isError":false}
{"type":"tool_execution_start","toolCallId":"t2","toolName":"bash","args":{"command":"say-hello"}}
{"type":"tool_execution_end","toolCallId":"t2","toolName":"bash","result":"SHOUTED-LONG-TOOL-ERROR-PAYLOAD words words words words words words words words words words words words words words words words words words words words words words words words","isError":true}
{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":2000,"errorMessage":"rate limited"}
{"type":"message_start","message":{"role":"assistant","content":[]}}
{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Recovered after the retry.\n"}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Recovered after the retry.\n"}],"stopReason":"stop"}}
{"type":"agent_end","messages":[],"willRetry":false}
{"type":"photo_capture","SECRET":"UNKNOWN-EVENT-PAYLOAD"}
'

render pi-json "$PI_STREAM"
expect_rc 0 "$RENDER_RC" "pi-json exit"
grep -q 'The answer is 42.' "$RENDER_OUT" || fail "pi: assistant text must be rendered"
if [[ "$(grep -c 'The answer is 42' "$RENDER_OUT")" -ne 1 ]]; then
  fail "pi: assistant text must appear exactly once (message_end must not duplicate deltas)"
fi
grep -q '\[think\]' "$RENDER_OUT" || fail "pi: thinking must open with [think]"
grep -q 'SECRET-THINKING-PAYLOAD' "$RENDER_OUT" || fail "pi: thinking text must be streamed"
grep -q 'SECRET-PARTIAL-PAYLOAD' "$RENDER_OUT" && fail "pi: tool partial results must never be dumped"
grep -q '\[tool\] read README.md' "$RENDER_OUT" || fail "pi: tool start must identify the tool and its target"
grep -q '\[done\] read' "$RENDER_OUT" || fail "pi: successful tool end must be labeled [done] with the tool name"
grep -q '\[tool\] bash say-hello' "$RENDER_OUT" || fail "pi: bash tool start must show the command"
grep -q '\[error\] bash:' "$RENDER_OUT" || fail "pi: failed tool end must be labeled [error] with the tool name"
grep -q 'SHOUTED-LONG-TOOL-ERROR-PAYLOAD words words words words words words words words words words words words words words words words words words words words words words words words' "$RENDER_OUT" &&
  fail "pi: tool error detail must be truncated, not dumped"
grep -q 'SHOUTED-LONG-TOOL-ERROR-PAYLOAD' "$RENDER_OUT" || fail "pi: tool error detail must still be identifiable"
grep -q '\[wait\] retry 1/3 in 2000ms: rate limited' "$RENDER_OUT" || fail "pi: auto retry must render as a wait"
grep -q 'Recovered after the retry.' "$RENDER_OUT" || fail "pi: text after a retry must render"
grep -q 'UNKNOWN-EVENT-PAYLOAD' "$RENDER_OUT" && fail "pi: unknown event payloads must never be dumped"
grep -q '\[note\].*photo_capture' "$RENDER_OUT" || fail "pi: unknown event types need a concise notice"

# A provider that does not stream deltas must still surface the final text
# from message_end, exactly once.
PI_NONDELTA='{"type":"message_start","message":{"role":"assistant","content":[]}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Final without deltas.\n"}],"stopReason":"stop"}}
'
render pi-json "$PI_NONDELTA"
expect_rc 0 "$RENDER_RC" "pi-json non-delta exit"
if [[ "$(grep -c 'Final without deltas' "$RENDER_OUT")" -ne 1 ]]; then
  fail "pi: non-delta message_end text must be rendered exactly once"
fi

# A failing assistant message (stopReason error/aborted) is a real error.
PI_ERROR='{"type":"message_start","message":{"role":"assistant","content":[]}}
{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"partial"}}
{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"partial"}],"stopReason":"error","errorMessage":"provider credit exhausted"}}
'
render pi-json "$PI_ERROR"
expect_rc 0 "$RENDER_RC" "pi-json error exit"
grep -q '\[error\] provider credit exhausted' "$RENDER_OUT" || fail "pi: assistant stopReason error must render the errorMessage"
grep -q '\[error\] .*partial' "$RENDER_OUT" && fail "pi: erroring message text must not be shown as an answer"

# Real Pi tool_execution_end uses result.content as [{type:text,text}].
# That shape must not crash jq and must not dump a long body on success.
PI_TYPED='{"type":"tool_execution_start","toolCallId":"t1","toolName":"read","args":{"path":"AGENTS.md"}}
{"type":"tool_execution_end","toolCallId":"t1","toolName":"read","result":{"content":[{"type":"text","text":"denied"}]},"isError":true}
{"type":"tool_execution_end","toolCallId":"t2","toolName":"read","result":{"content":[{"type":"text","text":"SECRET-TYPED-SUCCESS-BODY"}]},"isError":false}
'
render pi-json "$PI_TYPED"
expect_rc 0 "$RENDER_RC" "pi-json typed content exit"
grep -q '\[error\] read: denied' "$RENDER_OUT" || fail "pi: typed result.content text array must render as compact error text"
grep -q 'SECRET-TYPED-SUCCESS-BODY' "$RENDER_OUT" && fail "pi: successful typed tool body must not be dumped"
grep -q '\[done\] read' "$RENDER_OUT" || fail "pi: successful typed tool end must still be [done]"

# ESC / C0 in toolName and compaction reason must be sanitized.
PI_ESC_NAME='{"type":"tool_execution_start","toolCallId":"t1","toolName":"read\u001b[2J","args":{"path":"X"}}
{"type":"compaction_start","reason":"oversize\u0007"}
'
render pi-json "$PI_ESC_NAME"
expect_rc 0 "$RENDER_RC" "pi-json toolName escape exit"
if grep -q $'\x1b' "$RENDER_OUT"; then
  fail "pi: ESC inside toolName must be sanitized"
fi
if grep -q $'\x07' "$RENDER_OUT"; then
  fail "pi: BEL inside compaction reason must be sanitized"
fi
grep -q '\[tool\] read X' "$RENDER_OUT" || fail "pi: sanitized toolName must remain readable"
grep -q '\[wait\] compacting context (oversize)' "$RENDER_OUT" || fail "pi: sanitized reason must remain readable"


# -------------------------------------------------------------- claude-json

CLAUDE_STREAM='{"type":"system","subtype":"init","cwd":"/tmp/proj","session_id":"9a1b2c3d-4e5f-4a60-b1c2-d3e4f5a60719","model":"claude-opus-4-6","tools":["Bash","Read"]}
{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-6","content":[{"type":"thinking","thinking":"SECRET-CLAUDE-THINKING","signature":"x"},{"type":"text","text":"I will check the file."}]},"session_id":"9a1b2c3d"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"src/app.py"}}]},"session_id":"9a1b2c3d"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"def main(): ..."}]}]},"session_id":"9a1b2c3d"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"pytest -q"}}]},"session_id":"9a1b2c3d"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","is_error":true,"content":[{"type":"text","text":"CLAUDE-TOOL-ERROR words words words words words words words words words words words words words words words words words words words words words words words words words words"}]}]},"session_id":"9a1b2c3d"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Tests fail; here is the answer."}]},"session_id":"9a1b2c3d"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":42000,"num_turns":5,"result":"Tests fail; here is the answer.","session_id":"9a1b2c3d"}
{"type":"mystery_event","SECRET":"UNKNOWN-CLAUDE-PAYLOAD"}
'

render claude-json "$CLAUDE_STREAM"
expect_rc 0 "$RENDER_RC" "claude-json exit"
grep -q '\[run\] claude claude-opus-4-6 session 9a1b2c3d' "$RENDER_OUT" || fail "claude: init must identify model and session"
grep -q '\[think\]' "$RENDER_OUT" || fail "claude: thinking must open with [think]"
grep -q 'SECRET-CLAUDE-THINKING' "$RENDER_OUT" || fail "claude: thinking text must be shown"
grep -q 'signature' "$RENDER_OUT" && fail "claude: thinking signature must stay hidden"
grep -q 'I will check the file.' "$RENDER_OUT" || fail "claude: assistant text must render"
grep -q '\[tool\] Read src/app.py' "$RENDER_OUT" || fail "claude: tool_use must identify tool and target"
grep -q '\[done\] Read' "$RENDER_OUT" || fail "claude: ok tool_result must be labeled [done] with the tool name"
grep -q '\[tool\] Bash pytest -q' "$RENDER_OUT" || fail "claude: Bash tool_use must show the command"
grep -q '\[error\] Bash: CLAUDE-TOOL-ERROR' "$RENDER_OUT" || fail "claude: error tool_result must be labeled [error] with the tool name"
grep -q 'words words words words words words words words words words words words words words words words words words words words words words words words words words' "$RENDER_OUT" &&
  fail "claude: tool error detail must be truncated, not dumped"
if [[ "$(grep -c 'Tests fail; here is the answer.' "$RENDER_OUT")" -ne 1 ]]; then
  fail "claude: result duplicating the last assistant text must not be printed twice"
fi
grep -q '\[run\] result success' "$RENDER_OUT" || fail "claude: the terminal result must be acknowledged"
grep -q 'UNKNOWN-CLAUDE-PAYLOAD' "$RENDER_OUT" && fail "claude: unknown event payloads must never be dumped"
grep -q '\[note\].*mystery_event' "$RENDER_OUT" || fail "claude: unknown event types need a concise notice"

# A result that differs from the last assistant text is the final answer.
CLAUDE_DIFFERENT='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working on it."}]},"session_id":"s"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"num_turns":1,"result":"The distinct final answer."}
'
render claude-json "$CLAUDE_DIFFERENT"
expect_rc 0 "$RENDER_RC" "claude-json distinct result exit"
grep -q 'The distinct final answer.' "$RENDER_OUT" || fail "claude: a distinct result text must be rendered"

# Error results are rendered as errors, never as success.
CLAUDE_ERROR_RESULT='{"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":900,"num_turns":2,"result":"provider auth expired"}
'
render claude-json "$CLAUDE_ERROR_RESULT"
expect_rc 0 "$RENDER_RC" "claude-json error result exit"
grep -q '\[error\] result error_during_execution: provider auth expired' "$RENDER_OUT" ||
  fail "claude: an error result must render subtype and detail"

# Partial-message deltas (only present with --include-partial-messages) are
# dropped: the full assistant message is the single source shown.
CLAUDE_PARTIAL='{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"PAR"}}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"PAR TIAL"}]},"session_id":"s"}
{"type":"result","subtype":"success","is_error":false,"result":"PAR TIAL"}
'
render claude-json "$CLAUDE_PARTIAL"
expect_rc 0 "$RENDER_RC" "claude-json stream_event exit"
if [[ "$(grep -c 'PAR TIAL' "$RENDER_OUT")" -ne 1 ]]; then
  fail "claude: stream_event deltas must be dropped so the full message prints once"
fi
grep -q 'PAR' "$RENDER_OUT" || fail "claude: stream_event handling must not lose the message text"

# Expected rate_limit_event is quiet: no unknown-event spam, no payload dump.
CLAUDE_RATE='{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","SECRET":"RATE-LIMIT-PAYLOAD"},"session_id":"s"}
{"type":"system","subtype":"thinking_tokens","tokens":1}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
'
render claude-json "$CLAUDE_RATE"
expect_rc 0 "$RENDER_RC" "claude-json rate_limit exit"
grep -q 'RATE-LIMIT-PAYLOAD' "$RENDER_OUT" && fail "claude: rate_limit_info must not be dumped"
grep -q 'unhandled claude event type: rate_limit' "$RENDER_OUT" &&
  fail "claude: rate_limit_event must not emit an unknown-event notice"
grep -q 'thinking_tokens' "$RENDER_OUT" && fail "claude: thinking_tokens must stay quiet"
grep -q 'ok' "$RENDER_OUT" || fail "claude: text after rate_limit_event must still render"


# ------------------------------------------------------------- cursor-json

# Shapes match completed probe 20260920-164615-0ff0679d: partial assistants
# have timestamp_ms only; full intermediates add model_call_id; the final
# snapshot has neither; tool_call uses nested readToolCall; result repeats
# the concatenated segments.
CURSOR_STREAM='{"type":"system","subtype":"init","model":"composer","session_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
{"type":"thinking","subtype":"delta","text":"SECRET-CURSOR-THINKING","session_id":"aaaaaaaa","timestamp_ms":1}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Checking the files. "}]},"session_id":"aaaaaaaa","timestamp_ms":1000}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Checking the files. "}]},"model_call_id":"mc1","session_id":"aaaaaaaa","timestamp_ms":1001}
{"type":"tool_call","subtype":"started","call_id":"c1","tool_call":{"toolCallId":"c1","readToolCall":{"args":{"path":"AGENTS.md"}}},"session_id":"aaaaaaaa","timestamp_ms":1002}
{"type":"tool_call","subtype":"completed","call_id":"c1","tool_call":{"toolCallId":"c1","readToolCall":{"args":{"path":"AGENTS.md"},"result":{"success":{"content":"SECRET-CURSOR-TOOL-PAYLOAD","path":"AGENTS.md"}}}},"session_id":"aaaaaaaa","timestamp_ms":1003}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]},"session_id":"aaaaaaaa","timestamp_ms":2000}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Checking the files. Done."}]},"session_id":"aaaaaaaa"}
{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"result":"Checking the files. Done.","session_id":"aaaaaaaa"}
'
render cursor-json "$CURSOR_STREAM"
expect_rc 0 "$RENDER_RC" "cursor-json exit"
grep -q '\[run\] cursor composer session aaaaaaaa' "$RENDER_OUT" || fail "cursor: init must identify model and session"
grep -q '\[think\]' "$RENDER_OUT" || fail "cursor: thinking must open with [think]"
grep -q 'SECRET-CURSOR-THINKING' "$RENDER_OUT" || fail "cursor: thinking text must be streamed"
grep -q 'Checking the files. ' "$RENDER_OUT" || fail "cursor: partial assistant text must render"
if [[ "$(grep -c 'Checking the files\.' "$RENDER_OUT")" -ne 1 ]]; then
  fail "cursor: full snapshot and result must not duplicate already-rendered partials"
fi
grep -q '\[tool\] read AGENTS.md' "$RENDER_OUT" || fail "cursor: tool start must use readToolCall args.path"
grep -q '\[done\] read' "$RENDER_OUT" || fail "cursor: successful tool end must be [done] read"
grep -q 'SECRET-CURSOR-TOOL-PAYLOAD' "$RENDER_OUT" && fail "cursor: tool payload must never be dumped"
grep -q 'Done.' "$RENDER_OUT" || fail "cursor: later partial text must join"
grep -q '\[run\] result success' "$RENDER_OUT" || fail "cursor: terminal result must be acknowledged"

# Whitespace-only partials must survive; the result is then a duplicate.
CURSOR_WS='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"a"}]},"timestamp_ms":1}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":" "}]},"timestamp_ms":2}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"b"}]},"timestamp_ms":3}
{"type":"result","subtype":"success","is_error":false,"result":"a b"}
'
render cursor-json "$CURSOR_WS"
expect_rc 0 "$RENDER_RC" "cursor-json whitespace partials exit"
[[ "$(tr -d '\n' < "$RENDER_OUT")" == *'a b'* ]] || fail "cursor: whitespace-only partials must join as a b"
if [[ "$(grep -o 'a b' "$RENDER_OUT" | wc -l | tr -d ' ')" -ne 1 ]]; then
  fail "cursor: result must not duplicate joined whitespace partials"
fi


# --------------------------------------------------------------- grok-json

# Shapes match completed probe 20260920-164615-29693300.
GROK_STREAM='{"type":"thought","data":"SECRET-GROK-THOUGHT"}
{"type":"text","data":"Reading "}
{"type":"text","data":"now."}
{"type":"tool_call","toolCallId":"t1","title":"read_file","toolName":"read_file","rawInput":{"target_file":"README.md"},"status":"pending","content":[]}
{"type":"tool_call_update","toolCallId":"t1","status":null,"content":[{"type":"secret","text":"SECRET-GROK-MID"}]}
{"type":"tool_call_update","toolCallId":"t1","status":"completed","rawOutput":{"FileContent":"SECRET-GROK-TOOL-PAYLOAD","type":"file"},"content":[]}
{"type":"usage","signature":"SECRET-GROK-SIGNATURE","usage":{}}
{"type":"available_commands","commands":[],"tools":[]}
{"type":"text","data":"\nAll good.\n"}
{"type":"end","stopReason":"end_turn","sessionId":"bbbbbbbb-cccc-dddd-eeee-ffffffffffff"}
'
render grok-json "$GROK_STREAM"
expect_rc 0 "$RENDER_RC" "grok-json exit"
grep -q '\[think\]' "$RENDER_OUT" || fail "grok: thought must open with [think]"
grep -q 'SECRET-GROK-THOUGHT' "$RENDER_OUT" || fail "grok: thought text must be streamed"
grep -q 'SECRET-GROK-SIGNATURE' "$RENDER_OUT" && fail "grok: usage signature must never be dumped"
grep -q 'SECRET-GROK-TOOL-PAYLOAD' "$RENDER_OUT" && fail "grok: rawOutput must never be dumped"
grep -q 'SECRET-GROK-MID' "$RENDER_OUT" && fail "grok: mid-update content must never be dumped"
grep -q 'Reading now.' "$RENDER_OUT" || fail "grok: text deltas must join"
grep -q '\[tool\] read_file README.md' "$RENDER_OUT" || fail "grok: tool_call must show name and target_file"
if [[ "$(grep -c '\[done\] read_file' "$RENDER_OUT")" -ne 1 ]]; then
  fail "grok: null-status update must not emit a second done line"
fi
grep -q 'All good.' "$RENDER_OUT" || fail "grok: text after tools must render"
grep -q '\[run\] result end_turn' "$RENDER_OUT" || fail "grok: end must acknowledge stopReason"
grep -q 'available_commands' "$RENDER_OUT" && fail "grok: available_commands must stay quiet"

GROK_FAIL='{"type":"tool_call","toolCallId":"t9","toolName":"read_file","rawInput":{"target_file":"missing"},"status":"pending","content":[]}
{"type":"tool_call_update","toolCallId":"t9","status":"failed","rawOutput":{"error":"not found"},"content":[]}
'
render grok-json "$GROK_FAIL"
expect_rc 0 "$RENDER_RC" "grok-json failed tool exit"
grep -q '\[error\] read_file: not found' "$RENDER_OUT" || fail "grok: failed tool_call_update must be [error]"


# ------------------------------------------------ streaming and robustness

# expect_early FORMAT LINE : proves the renderer emits output for the first
# event before the input closes, using a FIFO held open by the test and a
# bounded poll (5s) as deterministic synchronization.
expect_early() {
  local format="$1" line="$2" seen=""
  local fifo="$TMP/fifo.$$" out="$TMP/early.$$" err="$TMP/early.$$.err"
  mkfifo "$fifo" || fail "cannot create fifo"
  : > "$out"
  agent_output_render "$format" <"$fifo" >"$out" 2>"$err" &
  local pid=$!
  sleep 0.2
  exec 9>"$fifo"
  printf '%s\n' "$line" >&9
  local waited=0
  while [[ "$waited" -lt 50 ]]; do
    if [[ -s "$out" ]]; then seen=yes; break; fi
    sleep 0.1
    waited=$((waited + 1))
  done
  printf '%s\n' '{"type":"agent_end"}' >&9
  exec 9>&-
  wait "$pid" || true
  rm -f "$fifo"
  if [[ -z "$seen" ]]; then
    fail "$format: first event produced no output within 5s of arriving"
  fi
}

expect_early pi-json '{"type":"tool_execution_start","toolCallId":"t1","toolName":"read","args":{"path":"README.md"}}'
expect_early claude-json '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"early answer"}]},"session_id":"s"}'
expect_early text 'plain streaming line'

# Newline-free assistant bytes must be visible before EOF (no line-reader).
expect_partial_bytes() {
  local format="$1" event="$2" needle="$3"
  local fifo="$TMP/fifo.partial.$$" out="$TMP/partial.$$" err="$TMP/partial.$$.err"
  mkfifo "$fifo" || fail "cannot create fifo"
  : > "$out"
  agent_output_render "$format" <"$fifo" >"$out" 2>"$err" &
  local pid=$!
  sleep 0.2
  exec 9>"$fifo"
  printf '%s\n' "$event" >&9
  local waited=0 seen=""
  while [[ "$waited" -lt 50 ]]; do
    if grep -q -F "$needle" "$out" 2>/dev/null; then seen=yes; break; fi
    sleep 0.1
    waited=$((waited + 1))
  done
  exec 9>&-
  wait "$pid" || true
  rm -f "$fifo"
  if [[ -z "$seen" ]]; then
    fail "$format: newline-free text '$needle' not visible before EOF (got: $(cat "$out" 2>/dev/null))"
  fi
}

expect_partial_bytes pi-json \
  '{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"VISIBLE"}}' \
  "VISIBLE"
expect_partial_bytes grok-json '{"type":"text","data":"VISIBLE"}' "VISIBLE"
expect_partial_bytes cursor-json \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"VISIBLE"}]},"session_id":"s","timestamp_ms":1}' \
  "VISIBLE"

# Exact bytes: a newline-free delta must not gain an EOF newline.
render pi-json $'{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"VISIBLE"}}\n'
expect_rc 0 "$RENDER_RC" "pi-json exact VISIBLE bytes"
if [[ "$(cat "$RENDER_OUT")" != "VISIBLE" ]]; then
  fail "pi: newline-free delta must be exact bytes before/after EOF, got $(od -An -tx1 "$RENDER_OUT")"
fi

# Malformed JSON lines are diagnosed, drained, and remembered in the exit
# status; valid events before and after still render.
MALFORMED='{"type":"session","id":"aabbccdd-0000-0000-0000-000000000000"}
this is not json
{"type":"tool_execution_start","toolCallId":"t1","toolName":"read","args":{"path":"README.md"}}
{"type":"agent_end"}
'
render pi-json "$MALFORMED"
expect_rc 5 "$RENDER_RC" "pi-json malformed exit"
grep -q '\[run\] pi session aabbccdd' "$RENDER_OUT" || fail "pi: events before the malformed line must still render"
grep -q '\[tool\] read README.md' "$RENDER_OUT" || fail "pi: events after the malformed line must be drained and rendered"
grep -q 'malformed JSON event near input line 2' "$RENDER_OUT" || fail "pi: malformed line must be diagnosed with its line number"
grep -q 'this is not json' "$RENDER_OUT" || fail "pi: the malformed excerpt should be shown for diagnosis"
grep -q 'malformed event line(s) skipped' "$RENDER_ERR" || fail "pi: stderr must summarize the malformed count"

# The same malformed line through the JSON formats only; text mode is a
# passthrough format and must not fail on non-JSON lines.
render text $'not json either\nbut plain text\n'
expect_rc 0 "$RENDER_RC" "text mode ignores JSON well-formedness"
grep -q 'but plain text' "$RENDER_OUT" || fail "text: malformed check must not drop text lines"

# A JSON line that is not an object is an invalid shape: drain, no payload
# dump, honest nonzero exit.
render pi-json $'[1,2,3,"SECRET-ARRAY-PAYLOAD"]\n{"type":"tool_execution_start","toolCallId":"t1","toolName":"read","args":{"path":"README.md"}}\n'
expect_rc 5 "$RENDER_RC" "pi-json non-object exit"
grep -q 'non-object JSON event' "$RENDER_OUT" || fail "pi: non-object JSON needs an honest invalid-shape notice"
grep -q 'SECRET-ARRAY-PAYLOAD' "$RENDER_OUT" && fail "pi: non-object payload must not be dumped"
grep -q '\[tool\] read README.md' "$RENDER_OUT" || fail "pi: events after an invalid shape must still render"

# Handler throw (typed field that is not a string where a string is walked
# by a leftover path) is caught: drain, exit 5, no duplicate later events.
PI_BAD_DELTA=$'{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":["SECRET-DELTA-ARRAY"]}}\n{"type":"tool_execution_start","toolCallId":"t1","toolName":"read","args":{"path":"README.md"}}\n'
render pi-json "$PI_BAD_DELTA"
# Coerced to empty (clean rejects non-strings) so this is a skip, not a crash.
expect_rc 0 "$RENDER_RC" "pi-json non-string delta coerced"
grep -q 'SECRET-DELTA-ARRAY' "$RENDER_OUT" && fail "pi: non-string delta must not be dumped"
grep -q '\[tool\] read README.md' "$RENDER_OUT" || fail "pi: events after a bad delta must still render"
if [[ "$(grep -c '\[tool\] read README.md' "$RENDER_OUT")" -ne 1 ]]; then
  fail "pi: drained events must not be duplicated"
fi

# Public API without pipefail: jq/status must not collapse to 0.
PIPEFAIL_RC=0
set +e
set +o pipefail
printf '%s\n' 'this is not json' | agent_output_render pi-json >"$TMP/pf.out" 2>"$TMP/pf.err"
PIPEFAIL_RC=$?
set -e
set -o pipefail
if [[ "$PIPEFAIL_RC" != 5 ]]; then
  fail "without pipefail, malformed input must still exit 5, got $PIPEFAIL_RC"
fi

# Piped output carries plain ASCII labels and no ANSI dependency.
render pi-json "$PI_STREAM"
if LC_ALL=C grep -q $'\x1b' "$RENDER_OUT"; then
  fail "piped output must not contain ANSI escape bytes"
fi
grep -q '^\[tool\] ' "$RENDER_OUT" || fail "labels must start at line start for piping"

# Terminal escapes can also arrive inside JSON string payloads (a tool that
# cats a binary, model echo) and must be sanitized the same way.
PI_ESCAPE='{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"clearing \u001b[2J\u001b[Hscreen"}}
'
render pi-json "$PI_ESCAPE"
expect_rc 0 "$RENDER_RC" "pi-json escaped-escape exit"
if grep -q $'\x1b' "$RENDER_OUT"; then
  fail "pi: escapes inside JSON payloads must be sanitized"
fi
grep -q 'clearing screen' "$RENDER_OUT" || fail "pi: sanitized payload text must remain readable"


# A delta that ends mid-line must not glue the next labeled line to it.
PI_MIDLINE='{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"partial answer without newline"}}
{"type":"tool_execution_start","toolCallId":"t1","toolName":"read","args":{"path":"README.md"}}
'
render pi-json "$PI_MIDLINE"
expect_rc 0 "$RENDER_RC" "pi-json midline exit"
grep -q 'partial answer without newline' "$RENDER_OUT" || fail "pi: mid-line delta must render"
grep -q '^\[tool\] read README.md' "$RENDER_OUT" || fail "pi: a label after mid-line text must start on a fresh line"

# Full chain: renderer then presentation, newline-free progress before EOF.
if [[ -f "$ROOT/lib/agent-present.sh" ]]; then
  # shellcheck source=../lib/agent-present.sh
  source "$ROOT/lib/agent-present.sh"
  chain_fifo="$TMP/chain.in"
  chain_out="$TMP/chain.out"
  mkfifo "$chain_fifo" || fail "cannot create chain fifo"
  : > "$chain_out"
  (
    export AGENT_RUN_COLOR=never TERM=dumb
    agent_output_render pi-json <"$chain_fifo" | agent_present_stream >"$chain_out"
  ) &
  chain_pid=$!
  sleep 0.2
  exec 8>"$chain_fifo"
  printf '%s\n' '{"type":"message_update","usage":{},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"short progress"}}' >&8
  chain_seen=""
  chain_wait=0
  while [[ "$chain_wait" -lt 50 ]]; do
    if grep -q -F 'short progress' "$chain_out" 2>/dev/null; then chain_seen=yes; break; fi
    sleep 0.1
    chain_wait=$((chain_wait + 1))
  done
  printf '%s\n' '{"type":"tool_execution_start","toolCallId":"t1","toolName":"read","args":{"path":"README.md"}}' >&8
  exec 8>&-
  wait "$chain_pid" || true
  rm -f "$chain_fifo"
  if [[ -z "$chain_seen" ]]; then
    fail "chain: newline-free progress not visible before EOF (got: $(cat "$chain_out" 2>/dev/null))"
  fi
  grep -q 'read README.md' "$chain_out" || fail "chain: tool line must still render after progress"
fi

# A repeated Codex final answer is printed once. log bytes are not this filter's job.
dedupe_run="$(mktemp -d)"
printf '%s\n' 'README.md is the only documentation file.' > "$dedupe_run/last-message.txt"
# shellcheck source=/dev/null
. "$ROOT/lib/run-capture.sh"
run="$dedupe_run"
deduped="$(printf '%s\n' 'README.md is the only documentation file.' 'tokens used' '99' 'README.md is the only documentation file.' | run_capture_dedupe_stream)"
grep -qx 'tokens used' <<<"$deduped" || fail "dedupe must keep the lines around the answer"
[[ "$(printf '%s\n' "$deduped" | grep -c 'only documentation file')" == 1 ]] || fail "dedupe must print the final answer once"
rm -rf "$dedupe_run"

echo "agent-output test: all assertions passed"
