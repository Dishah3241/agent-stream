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
unset NO_COLOR AGENT_RUN_RUN

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

for m in events render display-write terminal errtee; do
  [[ "$(marker "$J/$m")" == 0 ]] || fail "marker $m must be 0, got $(marker "$J/$m")"
done
[[ ! -e "$J/stdout.fifo" && ! -e "$J/stderr.fifo" ]] || fail "capture fifos must be removed"

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

echo "run-capture test: all assertions passed"
