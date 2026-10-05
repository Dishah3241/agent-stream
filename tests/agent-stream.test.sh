#!/usr/bin/env bash
set -euo pipefail

# bin/agent-stream over fake workers: run builds the header, keeps the
# record, exits with the worker's status; state and follow read it back;
# the help text and argument errors are usable.

fail() { echo "agent-stream test: ${*:-assertion failed at line ${BASH_LINENO[0]}}" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/agent-stream"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export AGENT_RUN_COLOR=never TERM=xterm LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
# A UTF-8 locale the system has, so fixture workers print no setlocale
# warning on stderr (that stderr is captured and compared byte for byte).
for _l in en_US.UTF-8 C.UTF-8 en_US.utf8; do
  if [[ -z "$(LC_ALL=$_l bash -c ':' 2>&1)" ]]; then export LC_ALL="$_l" LANG="$_l"; break; fi
done
export AGENT_STREAM_HOME="$TMP/home"
unset NO_COLOR AGENT_RUN_RUN AGENT_RUN_STATUS

# A project directory with a git branch so detection has something to find.
PROJ="$TMP/proj"
mkdir -p "$PROJ"
( cd "$PROJ" && git init -q . && git checkout -q -b feature/pane 2>/dev/null \
  && printf 'x\n' >f && git add f && git -c user.name=t -c user.email=t@example.invalid commit -qm i )

cat >"$TMP/worker" <<'WORKER'
#!/usr/bin/env bash
printf '%s\n' '{"type":"system","subtype":"init","model":"fixture-model","session_id":"aaaaaaaa-0000","cwd":"/w"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"Read it","status":"in_progress"},{"content":"Fix it","status":"pending"}]}}]}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Todos have been modified successfully"}]}}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/w/f"}}]}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"HIDDEN-BODY"}]}}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed."}]}}'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"num_turns":2,"result":"Fixed."}'
exit 4
WORKER
chmod +x "$TMP/worker"

# ---------------------------------------------------------------- run ----

rc=0
( cd "$PROJ" && "$BIN" run --agent claude --task "$(printf 'Fix the thing.\nSecond line of the task.')" --id run1 -- "$TMP/worker" ) >"$TMP/pane" 2>"$TMP/pane-err" || rc=$?
[[ "$rc" == 4 ]] || fail "run must exit with the worker's status, got $rc ($(cat "$TMP/pane-err"))"
REC="$TMP/home/runs/run1"
[[ -d "$REC" ]] || fail "record directory under AGENT_STREAM_HOME/runs/<id>"
for f in header.json task.txt events.jsonl stderr.txt log.txt display.txt state.json exit capture state; do
  [[ -e "$REC/$f" ]] || fail "record must contain $f"
done
[[ "$(cat "$REC/exit")" == 4 ]] || fail "exit marker holds the worker status"
[[ "$(cat "$REC/capture")" == 0 ]] || fail "capture marker is 0 for a clean capture"
[[ "$(jq -r .project "$REC/header.json")" == "proj" ]] || fail "project detected from the git top-level"
[[ "$(jq -r .branch "$REC/header.json")" == "feature/pane" ]] || fail "branch detected from git"
[[ "$(jq -r .agent "$REC/header.json")" == "claude" ]] || fail "agent recorded"
[[ "$(jq -r .label "$REC/header.json")" == "Fix the thing." ]] || fail "label is the first task line"
[[ "$(jq -r .task "$REC/header.json")" == $'Fix the thing.\nSecond line of the task.' ]] || fail "task saved in full in the header"
[[ "$(cat "$REC/task.txt")" == $'Fix the thing.\nSecond line of the task.' ]] || fail "task.txt holds the full task"
[[ "$(jq -r .status "$REC/state.json")" == "ended" ]] || fail "state ended"
[[ "$(jq -r .outcome.kind "$REC/state.json")" == "failed" ]] || fail "exit 4 is a failed outcome"
[[ "$(jq -r .outcome.exit "$REC/state.json")" == 4 ]] || fail "state carries the exit status"
[[ "$(jq -r .project.branch "$REC/state.json")" == "feature/pane" ]] || fail "state carries the branch"
[[ "$(jq -r '.todo_counts.total' "$REC/state.json")" == 2 ]] || fail "state carries the plan"
[[ "$(jq -r '.todos[0].status' "$REC/state.json")" == "active" ]] || fail "TodoWrite in_progress is active"
[[ "$(jq -r .model "$REC/state.json")" == "fixture-model" ]] || fail "model from the stream"

pane="$(cat "$TMP/pane")"
case "$pane" in *"proj · feature/pane"*) ;; *) fail "pane header names the project and branch: $pane" ;; esac
case "$pane" in *"task    Fix the thing. Second line of the task."*) ;; *) fail "pane header shows the task folded to one line: $pane" ;; esac
grep -qx 'Second line of the task.' "$TMP/pane" && fail "the task is never printed raw across lines"
case "$pane" in *"── · plan"*"▸ 1/2 Read it"*"· 2/2 Fix it"*) ;; *) fail "pane shows the plan with marks: $pane" ;; esac
case "$pane" in *"✗ failed · exit 4"*) ;; *) fail "pane ends with the failed outcome and exit status" ;; esac
case "$pane" in *"record  "*"runs/run1/"*) ;; *) fail "pane ending names the record" ;; esac
grep -q 'HIDDEN-BODY' "$TMP/pane" && fail "tool bodies never reach the pane"
grep -q 'HIDDEN-BODY' "$REC/display.txt" && fail "tool bodies never reach display.txt"
grep -q "$(printf '\033')" "$REC/display.txt" && fail "display.txt stays plain"
grep -qx '\[todo\] 1/2 active Read it' "$REC/display.txt" || fail "display.txt carries the plan lines"
tail -n 1 "$REC/display.txt" | grep -q '^\[end\] failed exit 4 elapsed [0-9]*s record ' || fail "display.txt ends with the [end] line, got: $(tail -n 1 "$REC/display.txt")"

# ---------------------------------------------------------------- state ----

state_out="$("$BIN" state "$REC")"
[[ "$(jq -r .id <<<"$state_out")" == "run1" ]] || fail "state prints state.json"
rebuilt="$("$BIN" state "$REC" --rebuild)"
[[ "$(jq -r .counts.tools <<<"$rebuilt")" == 1 ]] || fail "rebuild from display.txt counts tools (TodoWrite is a plan, not a tool)"
[[ "$(jq -r .outcome.exit <<<"$rebuilt")" == 4 ]] || fail "rebuild reads the [end] line"
[[ "$(jq -r .project.name <<<"$rebuilt")" == "proj" ]] || fail "rebuild seeds from header.json"

# ---------------------------------------------------------------- follow ---

follow_out="$("$BIN" follow "$REC")"
case "$follow_out" in *"proj · feature/pane"*"Read it"*"✗ failed · exit 4"*) ;; *) fail "follow replays header, stream, and ending: $follow_out" ;; esac

# --------------------------------------------------------- explicit args ---

rc=0
( cd "$PROJ" && "$BIN" run --format claude-json --id run2 -- "$TMP/worker" ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 4 ]] || fail "--format without --agent and without a task still runs"
[[ -f "$TMP/home/runs/run2/display.txt" ]] || fail "second record exists"
[[ ! -e "$TMP/home/runs/run2/task.txt" ]] || fail "no task means no task.txt"

# text format through the entry point
cat >"$TMP/textworker" <<'W'
#!/usr/bin/env bash
printf 'plain line\n'
printf '\033[31mred\033[0m\n'
W
chmod +x "$TMP/textworker"
rc=0
"$BIN" run --agent codex --task t --dir "$TMP/textrec" -- "$TMP/textworker" >"$TMP/textpane" 2>&1 || rc=$?
[[ "$rc" == 0 ]] || fail "text worker exit 0, got $rc: $(cat "$TMP/textpane")"
grep -q "$(printf '\033')" "$TMP/textrec/log.txt" || fail "text log keeps raw bytes"
grep -q "$(printf '\033')" "$TMP/textrec/display.txt" && fail "text display is plain"
[[ "$(jq -r .status "$TMP/textrec/state.json")" == "ended" ]] || fail "text runs get state too"
[[ "$(jq -r .outcome.kind "$TMP/textrec/state.json")" == "exited" ]] || fail "no harness result and exit 0 is exited"
grep -q '· exited · exit 0' "$TMP/textpane" || fail "text pane ending says exited"

# ---------------------------------------------------------------- nesting ---
# A run exports AGENT_STREAM_PARENT to its worker; an agent-stream run the
# worker starts records it as parent. --parent sets it explicitly, and a
# relative path is dropped rather than recorded wrong.

cat >"$TMP/outerworker" <<W
#!/usr/bin/env bash
printf 'outer sees %s\n' "\$AGENT_STREAM_PARENT"
"$BIN" run --agent codex --task inner --dir "$TMP/inner" -- "$TMP/textworker" >/dev/null 2>&1
W
chmod +x "$TMP/outerworker"
"$BIN" run --agent codex --task outer --dir "$TMP/outer" -- "$TMP/outerworker" >/dev/null 2>&1 || fail "outer run"
outer="$(cd "$TMP/outer" && pwd)"
grep -q "outer sees $outer" "$TMP/outer/display.txt" || fail "the worker sees its own record as AGENT_STREAM_PARENT"
[[ "$(jq -r .parent "$TMP/inner/header.json")" == "$outer" ]] || fail "a nested run records its parent in header.json"
[[ "$(jq -r .parent "$TMP/inner/state.json")" == "$outer" ]] || fail "a nested run records its parent in state.json"
[[ "$(jq -r .parent "$TMP/outer/state.json")" == "null" ]] || fail "a top-level run has no parent"
AGENT_STREAM_PARENT= "$BIN" run --agent codex --task x --parent "$TMP/elsewhere" --dir "$TMP/explicit" -- "$TMP/textworker" >/dev/null 2>&1
[[ "$(jq -r .parent "$TMP/explicit/state.json")" == "$TMP/elsewhere" ]] || fail "--parent sets the parent"
AGENT_STREAM_PARENT=relative/dir "$BIN" run --agent codex --task x --dir "$TMP/rel" -- "$TMP/textworker" >/dev/null 2>&1
[[ "$(jq -r .parent "$TMP/rel/state.json")" == "null" ]] || fail "a relative parent is dropped"

# ---------------------------------------------------------------- errors ---

rc=0
"$BIN" run --task x >/dev/null 2>"$TMP/err" || rc=$?
[[ "$rc" == 2 ]] || fail "missing agent and format is a usage error"
grep -q 'need --agent or --format' "$TMP/err" || fail "usage error names the fix"
rc=0
"$BIN" run --agent claude >/dev/null 2>"$TMP/err" || rc=$?
[[ "$rc" == 2 ]] || fail "missing task without argv is a usage error"
rc=0
"$BIN" bogus >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "unknown command is a usage error"
"$BIN" help | grep -q 'agent-stream run' || fail "help prints usage"
printf '%s\n' '{"type":"session","id":"abcdef12-0000"}' | "$BIN" render pi-json | grep -q '\[run\] pi session abcdef12' || fail "render subcommand"
printf '%s\n' '[done] read' | "$BIN" present | grep -q '✓ read' || fail "present subcommand"

echo "agent-stream test: all assertions passed"
