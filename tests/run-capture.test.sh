#!/usr/bin/env bash
set -euo pipefail

# run_capture_exec over a fake worker: the record directory keeps raw events,
# stderr, and the rendered display apart, and the worker's exit status is
# reported separately from the capture status.

fail() { echo "run-capture test: ${*:-assertion failed at line ${BASH_LINENO[0]}}" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export AGENT_RUN_COLOR=never TERM=xterm LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
unset NO_COLOR AGENT_RUN_RUN AGENT_RUN_STATUS
# A UTF-8 locale the system has, so fixture workers print no setlocale
# warning on stderr (that stderr is captured and compared byte for byte).
for _l in en_US.UTF-8 C.UTF-8 en_US.utf8; do
  if [[ -z "$(LC_ALL=$_l bash -c ':' 2>&1)" ]]; then export LC_ALL="$_l" LANG="$_l"; break; fi
done

# capture FORMAT RECORD_DIR WORKER: run_capture_exec in a subshell, because it
# manages its own EXIT trap and needs errexit off to read the worker's status.
# Pane output lands in RECORD_DIR.pane and "status capture" in RECORD_DIR.result.
capture() {
  local format="$1" dir="$2" worker="$3"
  mkdir -p "$dir"
  (
    set +e
    run="$dir"
    lib="$ROOT/lib"
    # shellcheck source=../lib/run-capture.sh
    . "$ROOT/lib/run-capture.sh"
    run_capture_exec "$format" -- "$worker" >"$dir.pane" 2>"$dir.pane-err"
    printf '%s %s\n' "$status" "$capture" >"$dir.result"
  )
}

marker() { cat "$1" 2>/dev/null || echo missing; }

# ------------------------------------------------------------ JSON worker ---

cat >"$TMP/json-worker" <<'WORKER'
#!/usr/bin/env bash
printf '%s\n' '{"type":"system","subtype":"init","model":"fixture-model","session_id":"aaaaaaaa-0000"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"README.md"}}]}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"HIDDEN-TOOL-BODY"}]}}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"The answer is 42."}]}}'
printf '%s\n' 'fixture warning on stderr' >&2
exit 3
WORKER
chmod +x "$TMP/json-worker"

J="$TMP/json"
capture claude-json "$J" "$TMP/json-worker"

[[ "$(cat "$J.result")" == "3 0" ]] || fail "worker exit 3 and clean capture must be reported apart, got: $(cat "$J.result")"
"$TMP/json-worker" 2>/dev/null >"$TMP/expected-events" || true
cmp -s "$TMP/expected-events" "$J/events.jsonl" || fail "events.jsonl must hold the worker's stdout byte for byte"
[[ "$(cat "$J/stderr.txt")" == "fixture warning on stderr" ]] || fail "stderr.txt must hold raw stderr"
{ cat "$J/events.jsonl"; cat "$J/stderr.txt"; } | cmp -s - "$J/log.txt" || fail "log.txt must be events followed by stderr"

grep -qx '\[tool\] Read README.md' "$J/display.txt" || fail "display.txt must carry the tool line"
grep -qx '\[done\] Read' "$J/display.txt" || fail "display.txt must close the tool"
grep -qx 'The answer is 42.' "$J/display.txt" || fail "display.txt must carry assistant text"
grep -q 'HIDDEN-TOOL-BODY' "$J/display.txt" && fail "display.txt must not dump a tool result body"
grep -q "$(printf '\033')" "$J/display.txt" && fail "display.txt must stay plain"

grep -q 'Read README.md' "$J.pane" || fail "the pane must show the tool card"
grep -q 'The answer is 42.' "$J.pane" || fail "the pane must show assistant text"
grep -q 'fixture warning on stderr' "$J.pane" || fail "the pane must show stderr as a note"
grep -q '^\[tool\]' "$J.pane" && fail "the pane must restyle label lines, not print them raw"

for m in events render display-write terminal errtee state; do
  [[ "$(marker "$J/$m")" == 0 ]] || fail "marker $m must be 0, got $(marker "$J/$m")"
done
[[ ! -e "$J/stdout.fifo" && ! -e "$J/stderr.fifo" && ! -e "$J/state.fifo" ]] || fail "capture fifos must be removed"

# Structured state: written during the run, finalized with the exit status,
# and the display ends with one plain [end] line that names the record.
[[ -s "$J/state.json" ]] || fail "state.json must exist"
[[ "$(jq -r .status "$J/state.json")" == "ended" ]] || fail "state must be ended"
[[ "$(jq -r .outcome.kind "$J/state.json")" == "failed" ]] || fail "exit 3 is a failed outcome, got $(jq -c .outcome "$J/state.json")"
[[ "$(jq -r .outcome.exit "$J/state.json")" == 3 ]] || fail "state carries the worker exit"
[[ "$(jq -r .outcome.capture "$J/state.json")" == "complete" ]] || fail "state carries the capture word"
[[ "$(jq -r .counts.tools "$J/state.json")" == 1 ]] || fail "state counts the tool"
[[ "$(jq -r .model "$J/state.json")" == "fixture-model" ]] || fail "state has the model from the stream"
[[ "$(jq -r .project.name "$J/state.json")" == "agent-stream" ]] || fail "project detected from the git top-level when no header is given, got $(jq -r .project.name "$J/state.json")"
[[ "$(jq -r .record.display "$J/state.json")" == "$J/display.txt" ]] || fail "state names the display file"
[[ "$(jq -r .id "$J/state.json")" == "json" ]] || fail "id falls back to the record directory name"
tail -n 1 "$J/display.txt" | grep -q "^\[end\] failed exit 3 elapsed [0-9]*s record $J\$" || fail "display.txt must end with the [end] line, got: $(tail -n 1 "$J/display.txt")"
grep -qx 'The answer is 42.' "$J/display.txt" || fail "the [end] line is appended after the stream, not instead of it"
grep -q '✗ failed · exit 3' "$J.pane" || fail "the pane must end with the outcome card"
grep -q "record  $J/" "$J.pane" || fail "the ending must say where the record is"
[[ ! -e "$J/task.txt" ]] || fail "no task known means no task.txt"

# A header with task, project, and branch: printed as context, saved in
# full, seeded into the state; the file on disk is left as written.
H="$TMP/header"
mkdir -p "$H"
printf '%s\n' '{"id":"20260920-161901-79f86825","agent":"claude","label":"Short label",
  "task":"Rewrite the pane so a glance tells me where the agent is.\nSecond paragraph with detail.",
  "project":"my-project","branch":"feature/pane","cwd":"/tmp","dir":"'"$H"'",
  "model_requested":"claude-opus-5-5","model_source":"flag"}' >"$H/header.json"
cp "$H/header.json" "$TMP/header.orig"
capture claude-json "$H" "$TMP/json-worker"
cmp -s "$TMP/header.orig" "$H/header.json" || fail "header.json must not be rewritten"
grep -q 'my-project · feature/pane' "$H.pane" || fail "pane header shows project and branch"
grep -q 'task    Rewrite the pane so a glance tells me where the agent is. Second paragraph…' "$H.pane" \
  || grep -q 'task    Rewrite the pane so a glance tells me where the agent is.' "$H.pane" \
  || fail "pane header shows the task shortened: $(grep task "$H.pane")"
[[ "$(cat "$H/task.txt")" == $'Rewrite the pane so a glance tells me where the agent is.\nSecond paragraph with detail.' ]] || fail "task.txt holds the full task"
[[ "$(jq -r .task "$H/state.json")" == $'Rewrite the pane so a glance tells me where the agent is.\nSecond paragraph with detail.' ]] || fail "state holds the full task"
[[ "$(jq -r .project.branch "$H/state.json")" == "feature/pane" ]] || fail "state takes the caller's branch"
[[ "$(jq -r .model_requested "$H/state.json")" == "claude-opus-5-5" ]] || fail "state records the requested model"
[[ "$(jq -r .agent "$H/state.json")" == "claude" ]] || fail "state records the agent"

# Nobody watching: the pane goes away after the first line, the record is
# still complete and the state still ends.
G="$TMP/gone"
mkdir -p "$G"
mkfifo "$G.pane-fifo"
head -n 1 <"$G.pane-fifo" >/dev/null &
gone_reader=$!
(
  set +e
  run="$G"
  lib="$ROOT/lib"
  # shellcheck source=../lib/run-capture.sh
  . "$ROOT/lib/run-capture.sh"
  run_capture_exec claude-json -- "$TMP/json-worker" >"$G.pane-fifo" 2>/dev/null
  printf '%s %s\n' "$status" "$capture" >"$G.result"
)
wait "$gone_reader" 2>/dev/null || true
[[ "$(cat "$G.result")" == "3 0" ]] || fail "a closed pane must not change the worker or capture status, got: $(cat "$G.result")"
cmp -s "$TMP/expected-events" "$G/events.jsonl" || fail "events.jsonl must be complete when the pane is gone"
grep -qx 'The answer is 42.' "$G/display.txt" || fail "display.txt must be complete when the pane is gone"
tail -n 1 "$G/display.txt" | grep -q '^\[end\] failed exit 3' || fail "the [end] line must be written when the pane is gone"
[[ "$(jq -r .status "$G/state.json")" == "ended" ]] || fail "state must end when the pane is gone"
[[ "$(marker "$G/events")" == 0 && "$(marker "$G/display-write")" == 0 ]] || fail "events and display markers stay 0 when only the pane failed (events=$(marker "$G/events") display-write=$(marker "$G/display-write"))"

# ------------------------------------------------------------ text worker ---

cat >"$TMP/text-worker" <<'WORKER'
#!/usr/bin/env bash
printf '\033[31mred line\033[0m\n'
printf 'plain line\n'
exit 0
WORKER
chmod +x "$TMP/text-worker"

T="$TMP/text"
capture text "$T" "$TMP/text-worker"

[[ "$(cat "$T.result")" == "0 0" ]] || fail "text worker must report exit 0 and clean capture, got: $(cat "$T.result")"
grep -q "$(printf '\033')" "$T/log.txt" || fail "log.txt must keep the worker's raw bytes"
grep -q "$(printf '\033')" "$T/display.txt" && fail "display.txt must be stripped of terminal controls"
grep -qx 'red line' "$T/display.txt" || fail "display.txt must keep the sanitized text"
grep -qx 'plain line' "$T.pane" || fail "the pane must show the text worker's output"
[[ "$(jq -r .status "$T/state.json")" == "ended" ]] || fail "text runs get a state too"
[[ "$(jq -r .outcome.kind "$T/state.json")" == "exited" ]] || fail "exit 0 without a harness result is exited"
[[ "$(jq -r .counts.text_lines "$T/state.json")" == 2 ]] || fail "text lines are counted"
tail -n 1 "$T/display.txt" | grep -q '^\[end\] exited exit 0' || fail "text display ends with the [end] line"
[[ "$(marker "$T/state")" == 0 ]] || fail "state marker for text runs"

echo "run-capture test: all assertions passed"
