#!/usr/bin/env bash
set -euo pipefail

# Agent Client Protocol: the acp-json renderer over protocol 2 (primary)
# and protocol 1 shapes taken from the published SDK 1.7.0 schemas, and
# the bridge in bin/agent-stream driving fake agents end to end (protocol 2
# offered by default and a protocol 1 answer accepted, permission answers,
# turn end under both protocols, grace kill, exit status).

fail() { echo "agent-acp test: ${*:-assertion failed at line ${BASH_LINENO[0]}}" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/agent-stream"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export AGENT_RUN_COLOR=never TERM=xterm LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
for _l in en_US.UTF-8 C.UTF-8 en_US.utf8; do
  if [[ -z "$(LC_ALL=$_l bash -c ':' 2>&1)" ]]; then export LC_ALL="$_l" LANG="$_l"; break; fi
done
unset NO_COLOR AGENT_RUN_RUN AGENT_RUN_STATUS AGENT_STREAM_ACP_PERMISSION AGENT_STREAM_ACP_VERSION AGENT_STREAM_ACP_GRACE
export AGENT_STREAM_HOME="$TMP/home"

# shellcheck source=../lib/agent-output.sh
source "$ROOT/lib/agent-output.sh"

render() {
  RENDER_OUT="$TMP/render.out"; RENDER_RC=0
  printf '%s' "$1" | agent_output_render acp-json >"$RENDER_OUT" 2>"$TMP/render.err" || RENDER_RC=$?
}

# ----------------------------------------------------------- protocol 1 ----

ACP1='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"fake-acp","version":"0.1"},"agentCapabilities":{}}}
{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess-1234abcd","modes":{"currentModeId":"default","availableModes":[]}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1234abcd","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"SECRET-ACP-PROMPT"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1234abcd","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"SECRET-ACP-THOUGHT"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1234abcd","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Starting the work."}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1234abcd","update":{"sessionUpdate":"plan","entries":[{"content":"Read the file","priority":"high","status":"in_progress"},{"content":"Edit it","priority":"medium","status":"pending"}]}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1234abcd","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","title":"Read README.md","kind":"read","status":"pending","rawInput":{"path":"README.md"},"locations":[{"path":"README.md"}]}}}
{"jsonrpc":"2.0","id":100,"method":"session/request_permission","params":{"sessionId":"sess-1234abcd","toolCall":{"toolCallId":"call_2","title":"Run `make test`","kind":"execute","rawInput":{"command":"make test"}},"options":[{"optionId":"reject","name":"Reject","kind":"reject_once"},{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1234abcd","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"SECRET-ACP-TOOL-OUTPUT"}}],"rawOutput":{"text":"SECRET-ACP-RAW"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1234abcd","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_2","title":"Run `make test`","kind":"execute","status":"failed","rawOutput":{"stderr":"make: *** [test] Error 1","SECRET":"ACP-RAW-STDERR-REST"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1234abcd","update":{"sessionUpdate":"plan","entries":[{"content":"Read the file","priority":"high","status":"completed"},{"content":"Edit it","priority":"medium","status":"in_progress"}]}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1234abcd","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":" Done.\n"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1234abcd","update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"SECRET-CMD"}]}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1234abcd","update":{"sessionUpdate":"current_mode_update","currentModeId":"plan"}}}
{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}
'
render "$ACP1"
[[ "$RENDER_RC" == 0 ]] || fail "acp1 render exit $RENDER_RC: $(cat "$TMP/render.err")"
grep -qx '\[note\] acp agent fake-acp 0.1 (protocol 1)' "$RENDER_OUT" || fail "initialize result names the agent and protocol: $(head -3 "$RENDER_OUT")"
grep -qx '\[run\] acp fake-acp session sess-123' "$RENDER_OUT" || fail "session/new result opens the run"
grep -q 'SECRET-ACP-PROMPT' "$RENDER_OUT" && fail "the user prompt echo stays quiet"
grep -q '^\[think\]' "$RENDER_OUT" || fail "agent_thought_chunk opens a think span"
grep -q 'SECRET-ACP-THOUGHT' "$RENDER_OUT" || fail "thought text is shown"
grep -q 'Starting the work.' "$RENDER_OUT" || fail "agent_message_chunk text renders"
grep -qx '\[todo\] 1/2 active Read the file' "$RENDER_OUT" || fail "plan entries render as todos"
grep -qx '\[todo\] 2/2 pending Edit it' "$RENDER_OUT" || fail "pending plan entry"
grep -qx '\[tool\] Read README.md' "$RENDER_OUT" || fail "tool_call title is the tool line"
grep -qx '\[wait\] permission: Run `make test`' "$RENDER_OUT" || fail "request_permission is a wait with the tool title: $(grep wait "$RENDER_OUT")"
grep -qx '\[done\] Read README.md' "$RENDER_OUT" || fail "tool_call_update completed closes the card by title"
grep -q 'SECRET-ACP-TOOL-OUTPUT\|SECRET-ACP-RAW\|ACP-RAW-STDERR-REST' "$RENDER_OUT" && fail "tool content and rawOutput are never dumped"
grep -qx '\[tool\] Run `make test`' "$RENDER_OUT" || fail "a tool first seen in an update still opens a card"
grep -qx '\[error\] Run `make test`: make: \*\*\* \[test\] Error 1' "$RENDER_OUT" || fail "failed tool shows a brief error: $(grep error "$RENDER_OUT")"
grep -qx '\[todo\] 1/2 done Read the file' "$RENDER_OUT" || fail "plan status change: done"
grep -qx '\[todo\] 2/2 active Edit it' "$RENDER_OUT" || fail "plan status change: active"
[[ "$(grep -c '^\[todo\]' "$RENDER_OUT")" == 4 ]] || fail "a repeated whole plan emits only changes"
grep -q 'SECRET-CMD' "$RENDER_OUT" && fail "available commands stay quiet"
grep -q 'unhandled' "$RENDER_OUT" && fail "known v1 updates are all handled: $(grep unhandled "$RENDER_OUT")"
grep -qx '\[run\] result end_turn' "$RENDER_OUT" || fail "the prompt response stopReason ends the run"
grep -q 'Done\.' "$RENDER_OUT" || fail "a later chunk after labels renders on its own line"

# ----------------------------------------------------------- protocol 2 ----

ACP2='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":2,"info":{"name":"fake-acp2","version":"2.0"},"capabilities":{}}}
{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess-v2-5678"}}
{"jsonrpc":"2.0","id":3,"result":{"messageId":"m1"}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"state_update","state":"running"}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"agent_message_chunk","messageId":"m5","content":{"type":"text","text":"Looking around once."}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"agent_thought_chunk","messageId":"th1","content":{"type":"text","text":"V2-THOUGHT-ONCE"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p1","entries":[{"content":"Inspect","priority":"high","status":"in_progress"},{"content":"Report","priority":"low","status":"pending"}]}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","title":"List files","kind":"search","status":"in_progress","rawInput":{"command":"ls"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"agent_thought","messageId":"th1","content":[{"type":"text","text":"V2-THOUGHT-ONCE"}]}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"agent_message","messageId":"m5","content":[{"type":"text","text":"Looking around once."}]}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"tool_call_content_chunk","toolCallId":"t1","content":{"type":"content","content":{"type":"text","text":"SECRET-V2-CHUNK"}}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"notice","severity":"warning","title":"Rate limited, retrying in 2s"}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"compaction_update","compactionId":"c1","status":"in_progress"}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"compaction_summary_chunk","compactionId":"c1","content":{"type":"text","text":"SECRET-V2-SUMMARY"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"compaction_update","compactionId":"c1","status":"completed","summary":"older turns folded"}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","rawOutput":{"stdout":"SECRET-V2-RAW"}}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"subagent_update","sessionId":"sub-1","state":{"state":"running"},"title":"Explore the tests"}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"agent_message","messageId":"m2","content":[{"type":"text","text":"All done."}]}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"usage_update","used":1,"size":2}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"state_update","state":"requires_action"}}}
{"jsonrpc":"2.0","id":200,"method":"session/request_permission","params":{"sessionId":"sess-v2-5678","title":"Write notes.txt","subject":{"type":"tool_call","toolCall":{"toolCallId":"t2","title":"Write notes.txt","kind":"edit","rawInput":{"path":"notes.txt","content":"SECRET-V2-PERMISSION-INPUT"}}},"options":[{"optionId":"a","name":"Allow","kind":"allow_once"}]}}
{"jsonrpc":"2.0","id":201,"method":"session/request_permission","params":{"sessionId":"sess-v2-5678","title":"Run a command","subject":{"type":"command","command":"make test","cwd":"/work/proj"},"options":[{"optionId":"a","name":"Allow","kind":"allow_once"}]}}
{"jsonrpc":"2.0","id":202,"method":"session/request_permission","params":{"sessionId":"sess-v2-5678","title":"","subject":{"type":"tool_call","toolCall":{"toolCallId":"t3","title":"Delete build/"}},"options":[{"optionId":"a","name":"Allow","kind":"allow_once"}]}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"plan_removed","planId":"p1"}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"mystery_update","SECRET":"V2-UNKNOWN"}}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-v2-5678","update":{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn","usage":{"totalTokens":12400,"inputTokens":11000,"outputTokens":1400}}}}
{"jsonrpc":"2.0","id":4,"error":{"code":-32603,"message":"boom"}}
'
render "$ACP2"
[[ "$RENDER_RC" == 0 ]] || fail "acp2 render exit $RENDER_RC: $(cat "$TMP/render.err")"
grep -qx '\[note\] acp agent fake-acp2 2.0 (protocol 2)' "$RENDER_OUT" || fail "v2 initialize result (info) names the agent"
grep -qx '\[run\] acp fake-acp2 session sess-v2-' "$RENDER_OUT" || fail "v2 session/new"
grep -q 'm1' "$RENDER_OUT" && fail "a v2 prompt response (messageId only) stays quiet"
grep -qx '\[todo\] 1/2 active Inspect' "$RENDER_OUT" || fail "v2 plan_update items render as todos"
grep -qx '\[tool\] List files' "$RENDER_OUT" || fail "v2 tool_call_update first sight opens the card"
grep -q 'SECRET-V2-CHUNK' "$RENDER_OUT" && fail "tool_call_content_chunk stays quiet"
grep -qx '\[warn\] Rate limited, retrying in 2s' "$RENDER_OUT" || fail "notice warning (v2 notices carry a title only)"
grep -qx '\[wait\] compacting context' "$RENDER_OUT" || fail "compaction in progress is a wait"
grep -q 'SECRET-V2-SUMMARY' "$RENDER_OUT" && fail "compaction summary chunks stay quiet"
grep -qx '\[note\] context compacted' "$RENDER_OUT" || fail "compaction completed"
grep -qx '\[done\] List files' "$RENDER_OUT" || fail "v2 tool completed"
grep -q 'SECRET-V2-RAW' "$RENDER_OUT" && fail "v2 rawOutput never dumped"
grep -qx '\[note\] subagent running: Explore the tests' "$RENDER_OUT" || fail "subagent_update"
grep -qx 'All done.' "$RENDER_OUT" || fail "v2 whole agent_message renders, also after an earlier message streamed as chunks"
[[ "$(grep -c 'Looking around once.' "$RENDER_OUT")" == 1 ]] || fail "a whole v2 message whose messageId streamed as chunks is not repeated"
[[ "$(grep -c 'V2-THOUGHT-ONCE' "$RENDER_OUT")" == 1 ]] || fail "a whole v2 thought whose messageId streamed as chunks is not repeated after a label line"
grep -qx '\[wait\] input: the agent needs your action' "$RENDER_OUT" || fail "requires_action is a wait"
grep -qx '\[wait\] permission: Write notes.txt' "$RENDER_OUT" || fail "v2 permission request uses the title: $(grep permission "$RENDER_OUT")"
grep -qx '\[wait\] permission: Run a command (make test)' "$RENDER_OUT" || fail "v2 command subject shows the command: $(grep permission "$RENDER_OUT")"
grep -qx '\[wait\] permission: Delete build/' "$RENDER_OUT" || fail "v2 empty title falls back to the subject tool call title: $(grep permission "$RENDER_OUT")"
grep -q 'SECRET-V2-PERMISSION-INPUT' "$RENDER_OUT" && fail "permission subject payloads are never dumped"
grep -qx '\[note\] plan removed' "$RENDER_OUT" || fail "plan_removed"
grep -qx '\[note\] unhandled acp update: mystery_update' "$RENDER_OUT" || fail "unknown update kinds are named"
grep -q 'V2-UNKNOWN' "$RENDER_OUT" && fail "unknown update payloads are not dumped"
grep -qx '\[run\] result end_turn (12400 tokens)' "$RENDER_OUT" || fail "v2 idle state_update with stopReason ends the run and carries the token total: $(grep result "$RENDER_OUT")"
grep -qx '\[error\] rpc -32603: boom' "$RENDER_OUT" || fail "error responses render"
grep -q 'usage_update' "$RENDER_OUT" && fail "usage_update stays quiet"

# Malformed and escape-laden ACP lines behave like every other format.
render $'{"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"x\\u001b[2Jy"}}}}\nnot json\n'
[[ "$RENDER_RC" == 5 ]] || fail "malformed acp line exits 5"
grep -q $'\x1b' "$RENDER_OUT" && fail "acp text is sanitized"
grep -q 'xy' "$RENDER_OUT" || fail "acp text survives sanitizing"

# The state tracker understands the result: plan removed clears the plan.
# shellcheck source=../lib/agent-state.sh
source "$ROOT/lib/agent-state.sh"
printf '%s' "$ACP2" | agent_output_render acp-json >"$TMP/acp2.display"
st="$(agent_state_build <"$TMP/acp2.display")"
[[ "$(jq -r .agent <<<"$st")" == "acp" ]] || fail "state agent is acp"
[[ "$(jq -r .model <<<"$st")" == "fake-acp2" ]] || fail "state model slot carries the ACP agent name"
[[ "$(jq -r '.todos | length' <<<"$st")" == 0 ]] || fail "plan removed clears the plan in the state"
[[ "$(jq -r .result.kind <<<"$st")" == "success" ]] || fail "end_turn is a success result"
[[ "$(jq -r .counts.tools <<<"$st")" == 1 ]] || fail "one tool"
[[ "$(jq -r .counts.tokens <<<"$st")" == 12400 ]] || fail "state counts the v2 token total, got $(jq -c .counts <<<"$st")"

# ------------------------------------------------------------- bridge ----

# Fake protocol 1 agent: answers initialize / session/new / session/prompt,
# asks one permission and records the answer, ends with a stopReason.
cat >"$TMP/fake-acp1" <<'AGENT'
#!/usr/bin/env bash
log="${FAKE_ACP_LOG:-/dev/null}"
u() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":%s}}\n' "$1"; }
while IFS= read -r line; do
  method="$(printf '%s' "$line" | jq -r '.method // ""')"
  id="$(printf '%s' "$line" | jq -c '.id // empty')"
  case "$method" in
    initialize)
      printf '%s\n' "$line" | jq -r '.params.protocolVersion' >>"$log"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1,"agentInfo":{"name":"fake-acp","version":"0.1"},"agentCapabilities":{}}}\n' "$id" ;;
    session/new)
      printf '%s\n' "$line" | jq -r '.params.cwd' >>"$log"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"sess-1234abcd"}}\n' "$id" ;;
    session/prompt)
      printf '%s\n' "$line" | jq -r '.params.prompt[0].text' >>"$log"
      u '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Working."}}'
      u '{"sessionUpdate":"plan","entries":[{"content":"Read the file","priority":"high","status":"in_progress"},{"content":"Edit it","priority":"low","status":"pending"}]}'
      printf '{"jsonrpc":"2.0","id":100,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"c2","title":"Run `make test`","kind":"execute"},"options":[{"optionId":"reject","name":"Reject","kind":"reject_once"},{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}\n'
      IFS= read -r resp
      printf '%s\n' "$resp" | jq -r '.result.outcome.optionId // .result.outcome.outcome' >>"$log"
      printf '{"jsonrpc":"2.0","id":101,"method":"fs/read_text_file","params":{"sessionId":"s1","path":"/x"}}\n'
      IFS= read -r resp
      printf '%s\n' "$resp" | jq -r '.error.code // "no-error"' >>"$log"
      u '{"sessionUpdate":"tool_call","toolCallId":"c2","title":"Run `make test`","kind":"execute","status":"completed"}'
      u '{"sessionUpdate":"plan","entries":[{"content":"Read the file","priority":"high","status":"completed"},{"content":"Edit it","priority":"low","status":"completed"}]}'
      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id" ;;
  esac
done
echo "stdin-closed" >>"$log"
exit "${FAKE_ACP_EXIT:-0}"
AGENT
chmod +x "$TMP/fake-acp1"

# Fake protocol 2 agent: prompt response carries only a messageId, the
# turn ends with an idle state_update; it lingers after idle until stdin
# closes (or forever when FAKE_ACP_LINGER is set, to exercise the grace kill).
cat >"$TMP/fake-acp2" <<'AGENT'
#!/usr/bin/env bash
log="${FAKE_ACP_LOG:-/dev/null}"
u() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s2","update":%s}}\n' "$1"; }
while IFS= read -r line; do
  method="$(printf '%s' "$line" | jq -r '.method // ""')"
  id="$(printf '%s' "$line" | jq -c '.id // empty')"
  case "$method" in
    initialize)
      printf '%s\n' "$line" | jq -r '"offered \(.params.protocolVersion) info \(.params.info.name)"' >>"$log"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":2,"info":{"name":"fake-acp2","version":"2.0"},"capabilities":{}}}\n' "$id" ;;
    session/new) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"sess-v2-5678"}}\n' "$id" ;;
    session/prompt)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"messageId":"m1"}}\n' "$id"
      u '{"sessionUpdate":"state_update","state":"running"}'
      u '{"sessionUpdate":"agent_message_chunk","messageId":"m1","content":{"type":"text","text":"Inspecting.\n"}}'
      u '{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p1","entries":[{"content":"Inspect","priority":"high","status":"completed"}]}}'
      u '{"sessionUpdate":"agent_message","messageId":"m2","content":[{"type":"text","text":"All done."}]}'
      if [[ -n "${FAKE_ACP_NOSTOP:-}" ]]; then
        u '{"sessionUpdate":"state_update","state":"idle","stopReason":null}'
      else
        u '{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn","usage":{"totalTokens":321,"inputTokens":300,"outputTokens":21}}'
      fi
      if [[ -n "${FAKE_ACP_LINGER:-}" ]]; then
        while true; do sleep 1; done
      fi ;;
  esac
done
echo "stdin-closed" >>"$log"
exit 0
AGENT
chmod +x "$TMP/fake-acp2"

PROJ="$TMP/proj"
mkdir -p "$PROJ"
export FAKE_ACP_LOG="$TMP/acp1.log"
rc=0
( cd "$PROJ" && "$BIN" run --agent acp --task "Make the tests pass" --id acp1 -- "$TMP/fake-acp1" ) >"$TMP/pane1" 2>"$TMP/pane1-err" || rc=$?
[[ "$rc" == 0 ]] || fail "bridge run must exit with the agent's status (0), got $rc: $(cat "$TMP/pane1-err")"
REC="$TMP/home/runs/acp1"
[[ "$(sed -n 1p "$FAKE_ACP_LOG")" == 2 ]] || fail "bridge offers protocolVersion 2 by default, got $(sed -n 1p "$FAKE_ACP_LOG")"
[[ "$(sed -n 2p "$FAKE_ACP_LOG")" == "$PROJ" ]] || fail "bridge sends the cwd in session/new, got $(sed -n 2p "$FAKE_ACP_LOG")"
[[ "$(sed -n 3p "$FAKE_ACP_LOG")" == "Make the tests pass" ]] || fail "bridge sends the task as the prompt"
[[ "$(sed -n 4p "$FAKE_ACP_LOG")" == "allow" ]] || fail "bridge allows by default (first allow option), got $(sed -n 4p "$FAKE_ACP_LOG")"
[[ "$(sed -n 5p "$FAKE_ACP_LOG")" == "-32601" ]] || fail "bridge declines fs requests with a JSON-RPC error"
[[ "$(sed -n 6p "$FAKE_ACP_LOG")" == "stdin-closed" ]] || fail "a protocol 1 answer is accepted: the bridge closes stdin after the prompt response"
[[ "$(jq -r .format "$REC/header.json")" == "acp-json" ]] || fail "record format is acp-json"
grep -qx '\[wait\] permission: Run `make test`' "$REC/display.txt" || fail "display carries the permission wait"
grep -qx '\[todo\] 2/2 done Edit it' "$REC/display.txt" || fail "display carries the plan"
grep -qx '\[run\] result end_turn' "$REC/display.txt" || fail "display carries the stop reason"
[[ "$(jq -r .outcome.kind "$REC/state.json")" == "success" ]] || fail "state outcome success, got $(jq -c .outcome "$REC/state.json")"
[[ "$(jq -r .todo_counts.done "$REC/state.json")" == 2 ]] || fail "state plan counts"
[[ "$(jq -r .model "$REC/state.json")" == "fake-acp" ]] || fail "state names the ACP agent"
grep -q '✓ done · exit 0' "$TMP/pane1" || fail "pane ending for the acp run: $(tail -5 "$TMP/pane1")"
grep -q '~ waiting (permission) Run `make test`' "$TMP/pane1" || fail "pane shows the permission wait"
grep -q '"jsonrpc"' "$TMP/pane1" && fail "raw JSON-RPC never reaches the pane"
head -n 1 "$REC/events.jsonl" | jq -e '.id == 1 and .result.protocolVersion == 1' >/dev/null || fail "events.jsonl holds the agent's raw JSON-RPC output"

# Deny policy and a failing agent exit status.
export FAKE_ACP_LOG="$TMP/acp1b.log"
rc=0
( cd "$PROJ" && AGENT_STREAM_ACP_PERMISSION=deny FAKE_ACP_EXIT=7 "$BIN" run --agent acp --task t --id acp1b -- "$TMP/fake-acp1" ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 7 ]] || fail "agent exit status passes through the bridge, got $rc"
[[ "$(sed -n 4p "$FAKE_ACP_LOG")" == "reject" ]] || fail "deny policy picks the reject option, got $(sed -n 4p "$FAKE_ACP_LOG")"
[[ "$(jq -r .outcome.kind "$TMP/home/runs/acp1b/state.json")" == "failed" ]] || fail "exit 7 is failed even after end_turn"

# An explicit protocol 1 offer still works.
export FAKE_ACP_LOG="$TMP/acp1c.log"
rc=0
( cd "$PROJ" && AGENT_STREAM_ACP_VERSION=1 "$BIN" run --agent acp --task t --id acp1c -- "$TMP/fake-acp1" ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 0 ]] || fail "protocol 1 offer run exit, got $rc"
[[ "$(sed -n 1p "$FAKE_ACP_LOG")" == 1 ]] || fail "AGENT_STREAM_ACP_VERSION=1 offers protocol 1"

# Protocol 2, the default: the turn ends on the idle state_update.
export FAKE_ACP_LOG="$TMP/acp2.log"
rc=0
( cd "$PROJ" && "$BIN" run --agent acp --task t --id acp2 -- "$TMP/fake-acp2" ) >"$TMP/pane2" 2>&1 || rc=$?
[[ "$rc" == 0 ]] || fail "v2 bridge run exit, got $rc: $(cat "$TMP/pane2")"
[[ "$(sed -n 1p "$FAKE_ACP_LOG")" == "offered 2 info agent-stream" ]] || fail "v2 initialize carries protocolVersion 2 and info, got $(sed -n 1p "$FAKE_ACP_LOG")"
[[ "$(sed -n 2p "$FAKE_ACP_LOG")" == "stdin-closed" ]] || fail "v2 bridge closes stdin after idle"
grep -qx '\[run\] result end_turn (321 tokens)' "$TMP/home/runs/acp2/display.txt" || fail "v2 idle stop reason and tokens recorded"
[[ "$(jq -r .counts.tokens "$TMP/home/runs/acp2/state.json")" == 321 ]] || fail "v2 tokens reach state.json"
grep -qx 'All done.' "$TMP/home/runs/acp2/display.txt" || fail "v2 message recorded"
[[ "$(jq -r .outcome.kind "$TMP/home/runs/acp2/state.json")" == "success" ]] || fail "v2 outcome success"

# Protocol 2 lets an idle stopReason be null: an idle after running still
# ends the turn, and the run ends as exited (no harness result), not hung.
export FAKE_ACP_LOG="$TMP/acp2b.log"
rc=0
( cd "$PROJ" && FAKE_ACP_NOSTOP=1 "$BIN" run --agent acp --task t --id acp2b -- "$TMP/fake-acp2" ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 0 ]] || fail "v2 null stopReason run exit, got $rc"
[[ "$(sed -n 2p "$FAKE_ACP_LOG")" == "stdin-closed" ]] || fail "idle after running closes stdin even without a stopReason"
[[ "$(jq -r .outcome.kind "$TMP/home/runs/acp2b/state.json")" == "exited" ]] || fail "no stop reason ends as exited, got $(jq -c .outcome "$TMP/home/runs/acp2b/state.json")"

# An agent that ignores stdin EOF is terminated after the grace period.
rc=0
( cd "$PROJ" && AGENT_STREAM_ACP_GRACE=1 FAKE_ACP_LINGER=1 "$BIN" run --agent acp --task t --id acp3 -- "$TMP/fake-acp2" ) >/dev/null 2>&1 || rc=$?
[[ "$rc" != 0 ]] || fail "a killed agent must not report success"
[[ "$(jq -r .status "$TMP/home/runs/acp3/state.json")" == "ended" ]] || fail "the record still ends after a grace kill"

# Usage errors.
rc=0
"$BIN" run --agent acp --task t >/dev/null 2>"$TMP/err" || rc=$?
[[ "$rc" == 2 ]] || fail "acp without an agent command is a usage error"
grep -q 'needs the agent command' "$TMP/err" || fail "usage error explains the fix"

echo "agent-acp test: all assertions passed"
