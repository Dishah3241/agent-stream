#!/usr/bin/env bash
# Synthetic preview of the agent-run presentation layer: representative
# header, stream, run-record, and goal inputs flow through the four library
# functions so the layer can be eyeballed in a real terminal. This is a
# fixture for humans, not a test; tests/agent-present.test.sh owns the
# assertions.
#
#   tests/fixtures/agent-present/preview.sh                 # color forced
#   AGENT_RUN_COLOR=never tests/fixtures/agent-present/preview.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../../../lib/agent-present.sh
. "$ROOT/lib/agent-present.sh"

export AGENT_RUN_COLOR="${AGENT_RUN_COLOR:-always}"
RUNS="${FACTORY_RUNS_ROOT:-$HOME/.factory-runs}"

rule() { printf '\n%s\n' "──────────────────────────────────────────────────────────"; }

rule
printf '%s\n' "1 · run header (explicit model) + header (harness default)"
printf '%s\n' '{"id":"20260920-161901-79f86825","agent":"pi",
  "label":"Design and implement a beautiful, restrained terminal presentation layer",
  "cwd":"'"$HOME"'/Code/my-project",
  "dir":"'"$RUNS"'/20260920-161901-79f86825",
  "model_requested":"zai/glm-5.3","model_source":"settings"}' | agent_present_header
printf '%s\n' '{"id":"20260920-161902-5b1c99aa","agent":"grok","label":"Mechanical sweep of config docs",
  "cwd":"'"$HOME"'/Code/my-project","dir":"'"$RUNS"'/20260920-161902-5b1c99aa",
  "model_requested":null,"model_source":null}' | agent_present_header

rule
printf '%s\n' "2 · streamed work (semantic renderer lines, exactly as they arrive)"
printf '%s\n' \
  'I will start by reading the run-record library to match its conventions, then add the presentation functions.' \
  '[tool] read lib/run-record.sh' \
  '[done] read' \
  '[tool] grep "run_record_inspect" lib/*.sh' \
  '[done] grep' \
  '[warn] roster fallback in use for route implementation' \
  '[tool] write lib/agent-present.sh' \
  '[done] write' \
  '[error] bash: tests/agent-present.test.sh exited 1' \
  'The failure is in the palette assertion, not the renderer; fixing the expected style set now.' \
  '[tool] read tests/agent-present.test.sh' \
  '[done] read' | agent_present_stream

rule
printf '%s\n' "3 · record: completed, receipt present — ready for review, never accepted"
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

rule
printf '%s\n' "4 · record: failed"
printf '%s\n' '{"id":"20260920-161903-cc04d710","dir":"'"$RUNS"'/20260920-161903-cc04d710",
  "state":"failed","exit":1,"capture":"complete","capture_exit":0,
  "agent":"cursor","binary":"cursor","mode":"edit","project":"my-project",
  "cwd":"'"$HOME"'/Code/my-project","worktree":null,"branch":null,"lease_id":null,
  "tab_id":null,"pane_id":null,"label":"Mechanical sweep of config docs",
  "created":"2026-09-20T16:19:03Z","base_sha":null,"model_requested":null,"model_source":null,
  "purpose":"implementation","depth":0,"caller_agent":null,"caller_session":null,
  "parent_run":null,"wrapper_sha":null,"wrapper_dirty":false,
  "native_adapter":null,"native_session_id":null,"native":null,
  "startup":null,"receipt":null,
  "paths":{"meta":"'"$RUNS"'/20260920-161903-cc04d710/meta.json",
    "brief":"'"$RUNS"'/20260920-161903-cc04d710/brief.md",
    "log":"'"$RUNS"'/20260920-161903-cc04d710/log.txt",
    "exit":"'"$RUNS"'/20260920-161903-cc04d710/exit","capture":null},
  "problems":[]}' | agent_present_record

rule
printf '%s\n' "5 · record: capture failed — log not trusted even though exit was 0"
printf '%s\n' '{"id":"20260920-161904-de51e2b7","dir":"'"$RUNS"'/20260920-161904-de51e2b7",
  "state":"incomplete","exit":0,"capture":"failed","capture_exit":1,
  "agent":"pi","binary":"pi","mode":"edit","project":"my-project",
  "cwd":"'"$HOME"'/Code/my-project","worktree":null,"branch":null,"lease_id":null,
  "tab_id":null,"pane_id":null,"label":"Long rebuild of the seat installer",
  "created":"2026-09-20T16:19:04Z","base_sha":null,"model_requested":null,"model_source":null,
  "purpose":"implementation","depth":0,"caller_agent":null,"caller_session":null,
  "parent_run":null,"wrapper_sha":null,"wrapper_dirty":false,
  "native_adapter":null,"native_session_id":null,"native":null,
  "startup":null,"receipt":null,
  "paths":{"meta":"'"$RUNS"'/20260920-161904-de51e2b7/meta.json",
    "brief":"'"$RUNS"'/20260920-161904-de51e2b7/brief.md",
    "log":"'"$RUNS"'/20260920-161904-de51e2b7/log.txt",
    "exit":"'"$RUNS"'/20260920-161904-de51e2b7/exit",
    "capture":"'"$RUNS"'/20260920-161904-de51e2b7/capture"},
  "problems":["log capture failed (tee exit 1); log.txt may be incomplete"]}' | agent_present_record

rule
printf '%s\n' "6 · record: open — liveness unknown, agent-run --follow"
printf '%s\n' '{"id":"20260920-161905-ef02aa31","dir":"'"$RUNS"'/20260920-161905-ef02aa31",
  "state":"open","exit":null,"capture":null,"capture_exit":null,
  "agent":"pi","binary":"pi","mode":"read_only","project":"my-project",
  "cwd":"'"$HOME"'/Code/my-project","worktree":null,"branch":null,"lease_id":null,
  "tab_id":null,"pane_id":null,"label":"Research landing flow for the goal records",
  "created":"2026-09-20T16:19:05Z","base_sha":null,"model_requested":null,"model_source":null,
  "purpose":"consultation","depth":0,"caller_agent":null,"caller_session":null,
  "parent_run":null,"wrapper_sha":null,"wrapper_dirty":false,
  "native_adapter":null,"native_session_id":null,"native":null,
  "startup":null,"receipt":null,
  "paths":{"meta":"'"$RUNS"'/20260920-161905-ef02aa31/meta.json",
    "brief":"'"$RUNS"'/20260920-161905-ef02aa31/brief.md",
    "log":"'"$RUNS"'/20260920-161905-ef02aa31/log.txt",
    "exit":null,"capture":null},
  "problems":[]}' | agent_present_record

rule
printf '%s\n' "7 · record: invalid — nothing claimed, problems shown"
printf '%s\n' '{"id":"20260920-161906-ff33bb20","dir":"'"$RUNS"'/20260920-161906-ff33bb20",
  "state":"invalid","exit":null,"capture":null,"capture_exit":null,
  "agent":null,"binary":null,"mode":null,"project":null,"cwd":null,
  "worktree":null,"branch":null,"lease_id":null,"tab_id":null,"pane_id":null,
  "label":null,"created":null,"base_sha":null,"model_requested":null,"model_source":null,
  "purpose":null,"depth":null,"caller_agent":null,"caller_session":null,
  "parent_run":null,"wrapper_sha":null,"wrapper_dirty":null,
  "native_adapter":null,"native_session_id":null,"native":null,
  "startup":null,"receipt":null,
  "paths":{"meta":null,"brief":null,"log":null,"exit":null,"capture":null},
  "problems":["meta.json is a symlink","exit marker is not an exit status"]}' | agent_present_record

rule
printf '%s\n' "8 · record: cancelled native turn with process exit 0"
printf '%s\n' '{"id":"20260920-161907-aa44cc15","dir":"'"$RUNS"'/20260920-161907-aa44cc15",
  "state":"cancelled","exit":0,"capture":"complete","capture_exit":0,
  "agent":"grok","binary":"grok","mode":"edit","project":"my-project",
  "cwd":"'"$HOME"'/Code/my-project","worktree":null,"branch":null,"lease_id":null,
  "tab_id":null,"pane_id":null,"label":"Wide refactor of the herdr tab flow",
  "created":"2026-09-20T16:19:07Z","base_sha":null,"model_requested":null,"model_source":null,
  "purpose":"implementation","depth":0,"caller_agent":null,"caller_session":null,
  "parent_run":null,"wrapper_sha":null,"wrapper_dirty":false,
  "native_adapter":"grok","native_session_id":"7c1d0b9a-9999-8888-7777-666655554444",
  "native":{"adapter":"grok","id":"7c1d0b9a","found":true,
    "store":"'"$HOME"'/.grok/sessions/%2Fhome%2Fdev%2FCode%2Fmy-project/7c1d0b9a",
    "started_at":null,"last_activity":null,"model":null,"terminal":"cancelled",
    "stop_reason":"permission cancellation","cancellation":"user",
    "permission_tool":"write","final_text":null},
  "startup":null,"receipt":null,
  "paths":{"meta":"'"$RUNS"'/20260920-161907-aa44cc15/meta.json",
    "brief":"'"$RUNS"'/20260920-161907-aa44cc15/brief.md",
    "log":"'"$RUNS"'/20260920-161907-aa44cc15/log.txt",
    "exit":"'"$RUNS"'/20260920-161907-aa44cc15/exit",
    "capture":"'"$RUNS"'/20260920-161907-aa44cc15/capture"},
  "problems":[]}' | agent_present_record

rule
printf '%s\n' "9 · goal: attention — one done, one open, one launch failed, one idle"
printf '%s\n' '{"id":"goal-20260920-161901-abc12345","title":"Ship the goal flow",
  "state":"attention","dir":"'"$RUNS"'/.goals/goal-20260920-161901-abc12345",
  "planner":{"run":{"id":"20260920-161851-00112233","state":"completed","exit":0,
    "paths":{"log":"'"$RUNS"'/20260920-161851-00112233/log.txt"},
    "native_terminal":null}},
  "tasks":[
    {"id":"implement","agent":"pi","brief":"Add the goal flow.","read_only":false,
     "owns":["lib"],"status":"completed",
     "run":{"id":"20260920-161901-79f86825","state":"completed","exit":0,
       "paths":{"log":"'"$RUNS"'/20260920-161901-79f86825/log.txt"},
       "native_terminal":"completed"},
     "failure":null},
    {"id":"research","agent":"pi","brief":"Read goal-record.sh.","read_only":true,
     "owns":[],"status":"open",
     "run":{"id":"20260920-161905-ef02aa31","state":"open","exit":null,
       "paths":{"log":"'"$RUNS"'/20260920-161905-ef02aa31/log.txt"},
       "native_terminal":null},
     "failure":null},
    {"id":"docs","agent":"cursor","brief":"Document the flow.","read_only":false,
     "owns":["README.md"],"status":"launch_failed","run":null,
     "failure":{"message":"herdr tab create failed: pane budget exhausted"}},
    {"id":"polish","agent":"pi","brief":"Polish after review.","read_only":false,
     "owns":["lib"],"status":"not_started","run":null,"failure":null}
  ],
  "counts":{"planned":4,"not_started":1,"open":1,"completed":1,"failed":0,
    "cancelled":0,"incomplete":0,"invalid":0,"launch_failed":1},
  "paths":{"request":"'"$RUNS"'/.goals/goal-20260920-161901-abc12345/request.json"},
  "problems":["worker extra-9999 is not in the plan"]}' | agent_present_goal

rule
printf '%s\n' "10 · goal: needs_review — every run completed"
printf '%s\n' '{"id":"goal-20260920-162500-bcd23456","title":"Split the renderer from the wrapper",
  "state":"needs_review","dir":"'"$RUNS"'/.goals/goal-20260920-162500-bcd23456",
  "tasks":[
    {"id":"render","agent":"pi","brief":"Add the semantic renderer.","read_only":false,
     "owns":["lib"],"status":"completed",
     "run":{"id":"20260920-162455-22334455","state":"completed","exit":0,
       "paths":{"log":"'"$RUNS"'/20260920-162455-22334455/log.txt"},
       "native_terminal":"completed"},
     "failure":null},
    {"id":"present","agent":"pi","brief":"Add the presentation layer.","read_only":false,
     "owns":["lib"],"status":"completed",
     "run":{"id":"20260920-162458-33445566","state":"completed","exit":0,
       "paths":{"log":"'"$RUNS"'/20260920-162458-33445566/log.txt"},
       "native_terminal":"completed"},
     "failure":null}
  ],
  "counts":{"planned":2,"not_started":0,"open":0,"completed":2,"failed":0,
    "cancelled":0,"incomplete":0,"invalid":0,"launch_failed":0},
  "paths":null,"problems":[]}' | agent_present_goal

rule
