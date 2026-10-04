#!/usr/bin/env bash
set -euo pipefail

# agent-state tests: the state tracker turns activity protocol lines into
# state.json. Build mode prints the final state; track mode writes the file
# atomically while lines arrive; finish merges the exit status and prints
# the [end] line. Every string in the state is already sanitized upstream,
# but a stray control byte must still not crash the tracker.

fail() { echo "agent-state test: ${*:-assertion failed at line ${BASH_LINENO[0]}}" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../lib/agent-state.sh
source "$ROOT/lib/agent-state.sh"

q() { jq -r "$2" <<<"$1"; }

# ------------------------------------------------------------- build mode --

LINES='[run] claude claude-opus-5-5 session 3f9c2a71
I will read the README first.
[todo] 1/3 active Read the README
[todo] 2/3 pending Count its lines
[todo] 3/3 pending Report the count
[think]
SECRET-REASONING must not become last_text
[tool] Read README.md
[done] Read
[todo] 1/3 done Read the README
[todo] 2/3 active Count its lines
[step] Counting lines with wc
[tool] Bash make test
[error] Bash: make: *** [test] Error 1
The test target fails; the README is out of date.
[warn] roster fallback in use
[wait] permission: Write notes.txt (outside the working directory)'

state="$(printf '%s\n' "$LINES" | agent_state_build '{"id":"r1","task":"Count the lines","project":{"name":"demo","dir":"/w","branch":"main"}}')"
[[ "$(q "$state" .schema)" == "agent-stream/state/1" ]] || fail "schema tag"
[[ "$(q "$state" .id)" == "r1" ]] || fail "seed id must survive"
[[ "$(q "$state" .task)" == "Count the lines" ]] || fail "seed task must survive"
[[ "$(q "$state" .project.name)" == "demo" ]] || fail "seed project must survive"
[[ "$(q "$state" .agent)" == "claude" ]] || fail "agent from the [run] line, got $(q "$state" .agent)"
[[ "$(q "$state" .model)" == "claude-opus-5-5" ]] || fail "model from the [run] line"
[[ "$(q "$state" .session)" == "3f9c2a71" ]] || fail "session from the [run] line"
[[ "$(q "$state" .status)" == "waiting" ]] || fail "a trailing [wait] means waiting, got $(q "$state" .status)"
[[ "$(q "$state" .waiting.kind)" == "permission" ]] || fail "wait kind is the first word"
[[ "$(q "$state" .waiting.text)" == "Write notes.txt (outside the working directory)" ]] || fail "wait text"
[[ "$(q "$state" '.todos | length')" == 3 ]] || fail "three todos"
[[ "$(q "$state" '.todos[0].status')" == "done" ]] || fail "todo 1 done"
[[ "$(q "$state" '.todos[1].status')" == "active" ]] || fail "todo 2 active"
[[ "$(q "$state" '.todos[1].text')" == "Count its lines" ]] || fail "todo 2 text"
[[ "$(q "$state" '.todos[2].n')" == 3 ]] || fail "todo numbering"
[[ "$(q "$state" '.todo_counts | "\(.total) \(.done) \(.active) \(.pending)"')" == "3 1 1 1" ]] || fail "todo counts, got $(q "$state" .todo_counts)"
[[ "$(q "$state" .step)" == "Counting lines with wc" ]] || fail "step"
[[ "$(q "$state" .counts.tools)" == 2 ]] || fail "two tools"
[[ "$(q "$state" .counts.tool_errors)" == 1 ]] || fail "one tool error"
[[ "$(q "$state" .counts.errors)" == 1 ]] || fail "one error"
[[ "$(q "$state" .counts.warnings)" == 1 ]] || fail "one warning"
[[ "$(q "$state" .counts.waits)" == 1 ]] || fail "one wait"
[[ "$(q "$state" .counts.text_lines)" == 2 ]] || fail "two assistant text lines, got $(q "$state" .counts.text_lines)"
[[ "$(q "$state" .last_text)" == "The test target fails; the README is out of date." ]] || fail "last_text is the last assistant line"
grep -q 'SECRET-REASONING' <<<"$(q "$state" .last_text)" && fail "thinking text must not become last_text"
[[ "$(q "$state" .last_error)" == "Bash: make: *** [test] Error 1" ]] || fail "last_error"
[[ "$(q "$state" .outcome)" == "null" ]] || fail "no outcome before the end"
[[ "$(q "$state" .started_at)" =~ ^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T ]] || fail "started_at is a timestamp"

# A wait ends when any later activity arrives.
after="$(printf '%s\n' "$LINES" '[done] Write' | agent_state_build)"
[[ "$(q "$after" .status)" == "running" ]] || fail "activity after a wait clears it"
[[ "$(q "$after" .waiting)" == "null" ]] || fail "waiting is null once cleared"

# Plain text or an empty stream never resets the state (an empty jq update
# would otherwise null the whole object).
plain="$(printf '%s\n' 'hello' 'world' | agent_state_build '{"id":"keep"}')"
[[ "$(q "$plain" .id)" == "keep" ]] || fail "plain text must keep the seed"
[[ "$(q "$plain" .counts.text_lines)" == 2 ]] || fail "plain lines are counted"
empty="$(printf '' | agent_state_build '{"id":"e"}')"
[[ "$(q "$empty" .status)" == "starting" ]] || fail "no lines means starting"

# The harness result and the [end] line decide the outcome.
ended="$(printf '%s\n' '[run] result success (4210ms, 3 turns)' '[end] success exit 0 elapsed 12s record /r/x' | agent_state_build)"
[[ "$(q "$ended" .status)" == "ended" ]] || fail "ended"
[[ "$(q "$ended" .outcome.kind)" == "success" ]] || fail "success outcome"
[[ "$(q "$ended" .outcome.exit)" == 0 ]] || fail "exit from the end line"
[[ "$(q "$ended" .counts.turns)" == 3 ]] || fail "turns from the result line"
[[ "$(q "$ended" .elapsed_s)" == 12 ]] || fail "elapsed from the end line"
errres="$(printf '%s\n' '[error] result error_max_turns' '[run] result error_max_turns (10ms, 9 turns)' '[end] error exit 0 elapsed 1s record /r' | agent_state_build)"
[[ "$(q "$errres" .outcome.kind)" == "error" ]] || fail "an error result with exit 0 is an error, got $(q "$errres" .outcome.kind)"
[[ "$(q "$errres" .result.kind)" == "error" ]] || fail "result kind error"

# Summary notes feed the outcome; needs-action warnings stay warnings.
summ="$(printf '%s\n' '[note] summary: README.md: 3 lines' '[warn] needs action: approve the plan' | agent_state_build)"
[[ "$(q "$summ" .outcome.summary)" == "README.md: 3 lines" ]] || fail "summary note lands in outcome.summary"
[[ "$(q "$summ" .counts.notes)" == 0 ]] || fail "a summary note is not counted as a plain note"
[[ "$(q "$summ" .last_warning)" == "needs action: approve the plan" ]] || fail "needs action is the last warning"

# A plan that shrinks or re-numbers is replaced, not appended.
shrink="$(printf '%s\n' '[todo] 1/3 done a' '[todo] 2/3 pending b' '[todo] 3/3 pending c' '[todo] 1/2 done a' '[todo] 2/2 dropped b' | agent_state_build)"
[[ "$(q "$shrink" '.todos | length')" == 2 ]] || fail "plan shrinks to N"
[[ "$(q "$shrink" '.todo_counts.dropped')" == 1 ]] || fail "dropped is counted"
bad="$(printf '%s\n' '[todo] 9/3 done out of range' '[todo] nonsense' '[end] garbage' | agent_state_build)"
[[ "$(q "$bad" '.todos | length')" == 0 ]] || fail "malformed todo lines are ignored"
[[ "$(q "$bad" .status)" == "ended" ]] || fail "a malformed end line still ends the run"
[[ "$(q "$bad" .outcome.kind)" == "unknown" ]] || fail "malformed end is an unknown outcome"

# Control bytes in a line do not crash the tracker.
ctrl="$(printf '[tool] Bash \033[2Jrm\007\n' | agent_state_build)"
[[ "$(q "$ctrl" .counts.tools)" == 1 ]] || fail "tracker survives control bytes"

# ------------------------------------------------------------- track mode --

R="$TMP/rec"
mkdir -p "$R"
fifo="$TMP/in.fifo"
mkfifo "$fifo"
( agent_state_track "$R" '{"id":"live"}' <"$fifo" ) &
tracker=$!
exec 3>"$fifo"
printf '%s\n' '[run] pi session abcdef12' '[tool] read README.md' >&3
deadline=$((SECONDS + 5))
seen=""
while (( SECONDS < deadline )); do
  if [[ -s "$R/state.json" ]] && jq -e '.counts.tools == 1' "$R/state.json" >/dev/null 2>&1; then seen=1; break; fi
  sleep 0.1
done
[[ -n "$seen" ]] || fail "state.json must be written while the stream is open (got: $(cat "$R/state.json" 2>/dev/null))"
[[ "$(jq -r .status "$R/state.json")" == "running" ]] || fail "live state is running"
[[ "$(jq -r .id "$R/state.json")" == "live" ]] || fail "live state keeps the seed"
[[ ! -e "$R/state.json.tmp" ]] || fail "no temp file left behind after a write"
printf '%s\n' '[done] read' '[run] result end_turn' >&3
exec 3>&-
wait "$tracker" || fail "tracker must exit 0 at EOF"
[[ "$(jq -r .status "$R/state.json")" == "ended" ]] || fail "final state is ended after the result"

# A tracker with no record directory drains and fails quietly.
printf 'x\n' | agent_state_track "$TMP/missing" >/dev/null 2>&1 && fail "missing dir must return nonzero"

# ------------------------------------------------------------ finish mode --

end_line="$(agent_state_finish "$R" 0 complete)"
[[ "$end_line" == "[end] success exit 0 elapsed "*"s record $R" ]] || fail "finish prints the [end] line, got: $end_line"
[[ "$(jq -r .outcome.kind "$R/state.json")" == "success" ]] || fail "finish merges the outcome"
[[ "$(jq -r .outcome.exit "$R/state.json")" == 0 ]] || fail "finish merges the exit"
[[ "$(jq -r .outcome.capture "$R/state.json")" == "complete" ]] || fail "finish records capture"
[[ "$(jq -r .ended_at "$R/state.json")" != "null" ]] || fail "finish sets ended_at"

end_fail="$(agent_state_finish "$R" 3 complete)"
[[ "$end_fail" == "[end] failed exit 3"* ]] || fail "nonzero exit is failed whatever the harness said, got: $end_fail"

# Finish rebuilds a missing state.json from display.txt.
R2="$TMP/rec2"
mkdir -p "$R2"
printf '%s\n' '[run] grok session x' '[tool] read a' '[done] read' '[run] result cancelled' >"$R2/display.txt"
end2="$(agent_state_finish "$R2" 0 complete)"
[[ "$end2" == "[end] cancelled exit 0"* ]] || fail "a cancelled result with exit 0 is cancelled, got: $end2"
[[ "$(jq -r .counts.tools "$R2/state.json")" == 1 ]] || fail "rebuilt state counts the tools"
[[ "$(agent_state_outcome 0 "")" == "exited" ]] || fail "no result and exit 0 is merely exited"

echo "agent-state test: all assertions passed"
