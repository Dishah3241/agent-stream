#!/usr/bin/env bash
# Synthetic preview of the presentation layer: every state a pane can be in,
# in the order a run goes through them, so the layer can be eyeballed in a
# real terminal. This is a fixture for humans, not a test;
# tests/agent-present.test.sh owns the assertions.
#
#   tests/fixtures/agent-present/preview.sh                 # color forced
#   AGENT_RUN_COLOR=never tests/fixtures/agent-present/preview.sh
#   TERM=dumb tests/fixtures/agent-present/preview.sh        # ASCII marks
#   AGENT_RUN_STATUS=pinned tests/fixtures/agent-present/preview.sh  # footer
#   AGENT_STREAM_THEME=radio tests/fixtures/agent-present/preview.sh # one theme
#
# Sections 1 to 8 use the base look; section 9 shows every theme in themes/
# (or only AGENT_STREAM_THEME when set): launch header, a stream with a
# plan and easter eggs, and the ending.
#
# Sections 1 to 6 are one run from start to end; 7 and 8 are the record and
# goal views the private dispatcher renders with the same palette.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../../../lib/agent-present.sh
. "$ROOT/lib/agent-present.sh"

export AGENT_RUN_COLOR="${AGENT_RUN_COLOR:-always}"
GALLERY="${AGENT_STREAM_THEME:-}"
export AGENT_STREAM_THEME=plain
RUNS="${AGENT_STREAM_HOME:-$HOME/.agent-stream}/runs"
REC="$RUNS/20261004-050000-ab12cd34"

# A state file for the status card and the pinned footer: the presenter
# reads $run/state.json. This one is synthetic and lives in a temp dir.
STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT
run="$STATE_DIR"
export run
printf '%s\n' '{"schema":"agent-stream/state/1","id":"20261004-050000-ab12cd34","status":"running",
  "agent":"claude","model":"claude-sonnet-5-5","session":"3f9c2a71",
  "project":{"name":"agent-stream","dir":"'"$HOME"'/Code/agent-stream","branch":"main"},
  "task":"Rethink and rebuild how this repository shows a headless coding agent at work in a terminal pane.",
  "started_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
  "activity":{"kind":"tool","text":"Bash make test"},"step":null,"waiting":null,
  "todos":[{"n":1,"text":"Read the README","status":"done"},{"n":2,"text":"Count its lines","status":"active"},{"n":3,"text":"Report the count","status":"pending"}],
  "todo_counts":{"total":3,"done":1,"active":1,"pending":1,"dropped":0},
  "counts":{"tools":12,"errors":1},"last_error":"Bash: make: *** [test] Error 1",
  "record":{"dir":"'"$REC"'"}}' >"$STATE_DIR/state.json"

rule() { printf '\n%s\n' "══════════════════════════════════════════════════════════"; }

rule
printf '%s\n' "1 · start: context header (who, where, what)"
printf '%s\n' '{"id":"20261004-050000-ab12cd34","agent":"claude","project":"agent-stream","branch":"main",
  "task":"Rethink and rebuild how this repository shows a headless coding agent at work in a terminal pane. Hold the result to the standard of a careful engineer narrating their own work.",
  "cwd":"'"$HOME"'/Code/agent-stream","dir":"'"$REC"'",
  "model_requested":null,"model_source":null}' | agent_present_header
printf '%s\n' '{"id":"20260920-161902-5b1c99aa","agent":"grok","label":"Mechanical sweep of config docs",
  "cwd":"'"$HOME"'/Code/my-project","dir":"'"$RUNS"'/20260920-161902-5b1c99aa",
  "model_requested":"grok-4","model_source":"settings"}' | agent_present_header

rule
printf '%s\n' "2 · plan appears, then the first steps (activity lines as the renderer emits them)"
printf '%s\n' \
  '[run] claude claude-sonnet-5-5 session 3f9c2a71' \
  'I will read the README first, then count its lines and report.' \
  '[todo] 1/3 active Read the README' \
  '[todo] 2/3 pending Count its lines' \
  '[todo] 3/3 pending Report the count' \
  '[tool] Read README.md' \
  '[done] Read' \
  '[todo] 1/3 done Read the README' \
  '[todo] 2/3 active Count its lines' \
  '[step] Counting lines with wc' \
  '[tool] Bash wc -l README.md' \
  '[done] Bash' | agent_present_stream

rule
printf '%s\n' "3 · waiting states: permission, retry, compaction; a subagent; thinking"
printf '%s\n' \
  '[tool] Write notes.txt' \
  '[wait] permission: Write notes.txt (Path is outside allowed working directories)' \
  '[done] Write' \
  '[wait] retry 1/3 in 2000ms: rate limited' \
  '[note] subagent Explore started: List directory files' \
  '[note] subagent completed: Two entries found' \
  '[wait] compacting context (oversize)' \
  '[note] context compacted' \
  '[think]' \
  'The failure is in the palette assertion, not the renderer.' \
  'Fixing the expected style set now.' | agent_present_stream

rule
printf '%s\n' "4 · trouble: a failed tool, a warning, a denied permission in the result"
printf '%s\n' \
  '[tool] Bash make test' \
  '[error] Bash: make: *** [test] Error 1' \
  'The test target fails; the README is out of date.' \
  '[warn] needs action: approve the plan before the next step' \
  '[todo] 2/3 done Count its lines' \
  '[todo] 3/3 active Report the count' \
  '[note] summary: README.md: 3 lines (wc -l)' \
  '[run] result success (4210ms, 3 turns, 1 denied)' | agent_present_stream

rule
printf '%s\n' "5 · status card: terminal-only, every 40 lines, from state.json (shown here on demand)"
_ap_style_init
_ap_status_card

rule
printf '%s\n' "6 · ending cards: done, failed, harness error with exit 0, cancelled, exited"
printf '%s\n' '{"outcome":{"kind":"success","exit":0,"summary":"README.md: 3 lines (wc -l)"},"elapsed_s":252,
  "todo_counts":{"done":3,"total":3},"counts":{"tools":12,"errors":1},"task":"Rethink and rebuild how this repository shows a headless coding agent at work.",
  "record":{"dir":"'"$REC"'"}}' | agent_present_end
printf '%s\n' '{"outcome":{"kind":"failed","exit":1},"elapsed_s":42,"todo_counts":{"done":1,"total":3},
  "counts":{"tools":3,"errors":2},"last_error":"Bash: make: *** [test] Error 1",
  "record":{"dir":"'"$RUNS"'/20261004-051200-cc04d710"}}' | agent_present_end
printf '%s\n' '{"outcome":{"kind":"error","exit":0,"detail":"error_max_turns (90000ms, 40 turns)"},"elapsed_s":3700,
  "todo_counts":{"done":0,"total":0},"counts":{"tools":40,"errors":0},
  "record":{"dir":"'"$RUNS"'/20261004-052000-de51e2b7"}}' | agent_present_end
printf '%s\n' '{"outcome":{"kind":"cancelled","exit":0},"elapsed_s":5,"todo_counts":{"done":0,"total":2},
  "counts":{"tools":1,"errors":0},"record":{"dir":"'"$RUNS"'/20261004-052100-aa44cc15"}}' | agent_present_end
printf '%s\n' '{"outcome":{"kind":"exited","exit":0},"elapsed_s":5,"todo_counts":{"done":0,"total":0},
  "counts":{"tools":0,"errors":0},"record":{"dir":"'"$RUNS"'/20261004-052200-ef02aa31"}}' | agent_present_end
printf '%s\n' "   the same ending as a follower sees it in display.txt:"
printf '%s\n' '[end] success exit 0 elapsed 252s record '"$REC" | agent_present_stream

rule
printf '%s\n' "7 · dispatcher record views: completed, failed, incomplete capture, open, invalid, cancelled"
printf '%s\n' '{"id":"20260920-161901-79f86825","dir":"'"$RUNS"'/20260920-161901-79f86825",
  "state":"completed","exit":0,"capture":"complete","capture_exit":0,
  "agent":"pi","binary":"pi","mode":"edit","project":"my-project",
  "cwd":"'"$HOME"'/Code/my-project","worktree":null,"branch":null,"lease_id":null,
  "tab_id":null,"pane_id":null,"label":"Design the presentation layer",
  "created":"2026-09-20T16:19:01Z","base_sha":null,
  "model_requested":"zai/glm-5.3","model_source":"settings",
  "purpose":"implementation","depth":0,"caller_agent":null,"caller_session":null,
  "parent_run":null,"wrapper_sha":null,"wrapper_dirty":false,
  "native_adapter":"pi","native_session_id":"3f2a9c1e-1111-2222-3333-444455556666",
  "native":{"adapter":"pi","id":"3f2a9c1e","found":true,
    "store":"'"$RUNS"'/20260920-161901-79f86825/native/20260920_3f2a.jsonl",
    "started_at":"2026-09-20T16:19:05Z","last_activity":"2026-09-20T16:41:12Z",
    "model":null,"terminal":"completed","stop_reason":null,"cancellation":null,
    "permission_tool":null,"final_text":"receipt omitted here"},
  "startup":null,"receipt":"present",
  "paths":{"meta":"'"$RUNS"'/20260920-161901-79f86825/meta.json",
    "brief":"'"$RUNS"'/20260920-161901-79f86825/brief.md",
    "log":"'"$RUNS"'/20260920-161901-79f86825/log.txt",
    "exit":"'"$RUNS"'/20260920-161901-79f86825/exit",
    "capture":"'"$RUNS"'/20260920-161901-79f86825/capture"},
  "problems":[]}' | agent_present_record
printf '%s\n' '{"id":"20260920-161903-cc04d710","dir":"'"$RUNS"'/20260920-161903-cc04d710",
  "state":"failed","exit":1,"capture":"complete","capture_exit":0,
  "agent":"cursor","project":"my-project","cwd":"'"$HOME"'/Code/my-project",
  "label":"Mechanical sweep of config docs","model_requested":null,"model_source":null,
  "native":null,"startup":null,"receipt":null,
  "paths":{"log":"'"$RUNS"'/20260920-161903-cc04d710/log.txt"},"problems":[]}' | agent_present_record
printf '%s\n' '{"id":"20260920-161904-de51e2b7","dir":"'"$RUNS"'/20260920-161904-de51e2b7",
  "state":"incomplete","exit":0,"capture":"failed","capture_exit":1,
  "agent":"pi","project":"my-project","label":"Long rebuild of the seat installer",
  "model_requested":null,"model_source":null,"native":null,"startup":null,"receipt":null,
  "paths":{"log":"'"$RUNS"'/20260920-161904-de51e2b7/log.txt"},
  "problems":["log capture failed (tee exit 1); log.txt may be incomplete"]}' | agent_present_record
printf '%s\n' '{"id":"20260920-161905-ef02aa31","dir":"'"$RUNS"'/20260920-161905-ef02aa31",
  "state":"open","exit":null,"capture":null,"capture_exit":null,
  "agent":"pi","project":"my-project","label":"Research landing flow for the goal records",
  "model_requested":null,"model_source":null,"native":null,"startup":null,"receipt":null,
  "paths":{"log":"'"$RUNS"'/20260920-161905-ef02aa31/log.txt"},"problems":[]}' | agent_present_record
printf '%s\n' '{"id":"20260920-161906-ff33bb20","dir":"'"$RUNS"'/20260920-161906-ff33bb20",
  "state":"invalid","exit":null,"capture":null,"capture_exit":null,
  "agent":null,"project":null,"label":null,"model_requested":null,"model_source":null,
  "native":null,"startup":null,"receipt":null,"paths":{"log":null},
  "problems":["meta.json is a symlink","exit marker is not an exit status"]}' | agent_present_record
printf '%s\n' '{"id":"20260920-161907-aa44cc15","dir":"'"$RUNS"'/20260920-161907-aa44cc15",
  "state":"cancelled","exit":0,"capture":"complete","capture_exit":0,
  "agent":"grok","project":"my-project","label":"Wide refactor of the herdr tab flow",
  "model_requested":null,"model_source":null,
  "native":{"adapter":"grok","id":"7c1d0b9a","found":true,"store":"'"$HOME"'/.grok/sessions/7c1d0b9a",
    "terminal":"cancelled","stop_reason":"permission cancellation","cancellation":"user",
    "permission_tool":"write","final_text":null},
  "startup":null,"receipt":null,
  "paths":{"log":"'"$RUNS"'/20260920-161907-aa44cc15/log.txt"},"problems":[]}' | agent_present_record

rule
printf '%s\n' "8 · goal views: attention and needs_review"
printf '%s\n' '{"id":"goal-20260920-161901-abc12345","title":"Ship the goal flow",
  "state":"attention","dir":"'"$RUNS"'/.goals/goal-20260920-161901-abc12345",
  "planner":{"run":{"id":"20260920-161851-00112233","state":"completed","exit":0,
    "paths":{"log":"'"$RUNS"'/20260920-161851-00112233/log.txt"},"native_terminal":null}},
  "tasks":[
    {"id":"implement","agent":"pi","brief":"Add the goal flow.","read_only":false,
     "owns":["lib"],"status":"completed",
     "run":{"id":"20260920-161901-79f86825","state":"completed","exit":0,
       "paths":{"log":"'"$RUNS"'/20260920-161901-79f86825/log.txt"},"native_terminal":"completed"},
     "failure":null},
    {"id":"research","agent":"pi","brief":"Read goal-record.sh.","read_only":true,
     "owns":[],"status":"open",
     "run":{"id":"20260920-161905-ef02aa31","state":"open","exit":null,
       "paths":{"log":"'"$RUNS"'/20260920-161905-ef02aa31/log.txt"},"native_terminal":null},
     "failure":null},
    {"id":"docs","agent":"cursor","brief":"Document the flow.","read_only":false,
     "owns":["README.md"],"status":"launch_failed","run":null,
     "failure":{"message":"herdr tab create failed: pane budget exhausted"}},
    {"id":"polish","agent":"pi","brief":"Polish after review.","read_only":false,
     "owns":["lib"],"status":"not_started","run":null,"failure":null}
  ],
  "counts":{"planned":4,"not_started":1,"open":1,"completed":1,"failed":0,
    "cancelled":0,"incomplete":0,"invalid":0,"launch_failed":1},
  "problems":["worker extra-9999 is not in the plan"]}' | agent_present_goal
printf '%s\n' '{"id":"goal-20260920-162500-bcd23456","title":"Split the renderer from the wrapper",
  "state":"needs_review","dir":"'"$RUNS"'/.goals/goal-20260920-162500-bcd23456",
  "tasks":[
    {"id":"render","agent":"pi","brief":"Add the semantic renderer.","owns":["lib"],"status":"completed",
     "run":{"id":"20260920-162455-22334455","state":"completed","exit":0,
       "paths":{"log":"'"$RUNS"'/20260920-162455-22334455/log.txt"},"native_terminal":"completed"},
     "failure":null},
    {"id":"present","agent":"pi","brief":"Add the presentation layer.","owns":["lib"],"status":"completed",
     "run":{"id":"20260920-162458-33445566","state":"completed","exit":0,
       "paths":{"log":"'"$RUNS"'/20260920-162458-33445566/log.txt"},"native_terminal":"completed"},
     "failure":null}
  ],
  "counts":{"planned":2,"not_started":0,"open":0,"completed":2,"failed":0,
    "cancelled":0,"incomplete":0,"invalid":0,"launch_failed":0},
  "paths":null,"problems":[]}' | agent_present_goal

rule
printf '%s\n' "9 · themes: each design file in themes/, same run"
for theme in ${GALLERY:-space observatory blueprint radio bottling}; do
  printf '\n%s\n\n' ">>> theme: $theme"
  (
    export AGENT_STREAM_THEME="$theme"
    printf '%s\n' '{"id":"20261004-050000-ab12cd34","agent":"claude","project":"forge","branch":"main",
      "task":"Integrate the orbital model across the full parameter sweep and report convergence.",
      "cwd":"'"$HOME"'/Code/forge","dir":"'"$REC"'"}' | agent_present_header
    printf '%s\n' \
      '[run] claude claude-opus-5-5 session 3f9c2a71' \
      '[todo] 1/3 done Load the sweep' \
      '[todo] 2/3 active Integrate' \
      '[todo] 3/3 pending Report' \
      '[tool] Bash make integrate' \
      '[error] Bash: diverged' \
      '[tool] Bash make integrate' \
      '[error] Bash: diverged' \
      '[tool] Bash make integrate' \
      '[error] Bash: diverged' \
      '[wait] permission: Write results.csv' \
      '[step] lowering the step size' \
      'Converged after lowering the step size.' \
      '[run] result success (4210ms, 3 turns, 1 denied)' | agent_present_stream
    printf '%s\n' '{"id":"20261004-050000-ab12cd34","agent":"claude","task":"Integrate the orbital model",
      "outcome":{"kind":"success","exit":0,"summary":"converged at step 1e-4"},"elapsed_s":9000,
      "todo_counts":{"done":3,"total":3},"counts":{"tools":42,"errors":3},"record":{"dir":"'"$REC"'"}}' | agent_present_end
  )
done

if [[ "${AGENT_RUN_STATUS:-}" == pinned && -t 1 ]]; then
  rule
  printf '%s\n' "10 · pinned footer: the stream scrolls above a two-line status for ten seconds"
  for i in 1 2 3 4 5 6 7 8 9 10; do printf '[tool] Bash step %s\n[done] Bash\n' "$i"; sleep 1; done | agent_present_stream
fi
rule
