#!/usr/bin/env bash
set -euo pipefail

# agent-present tests execute the four presentation functions over pipes and
# assert readable semantics: plain output on non-TTYs, NO_COLOR precedence, a
# bounded quiet palette in forced color, sanitized control characters, and
# incremental streaming. Style numbers below are the library's documented
# palette, not implementation internals: 0 reset, 2 dim, 31 red error,
# 32 green success, 33 amber attention, 36 cyan heading.
#
# Environment is set here so TERM=dumb / locale at the caller cannot flip
# Unicode vs ASCII assertions. TERM=dumb, NO_COLOR, and UTF-8 are each
# covered by an explicit case.

fail() { echo "agent-present tests: $1 (line ${BASH_LINENO[0]})" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/lib/agent-present.sh"
[[ -f "$LIB" ]] || fail "missing library: $LIB"
# shellcheck source=../lib/agent-present.sh
source "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Default assertions run in a UTF-8, non-dumb terminal. Color stays off
# unless a test opts in. An ambient NO_COLOR must not leak into opt-in tests.
export AGENT_RUN_COLOR=never
export TERM=xterm
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
unset NO_COLOR

ESC=$'\033'
CR=$'\r'

has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
assert_has() { has "$1" "$2" || fail "output lacks: $2"; }
assert_lacks() { if has "$1" "$2"; then fail "output must not contain: $2"; fi; }
assert_no_ansi() {
  case "$1" in
    *"$ESC"*|*"$CR"*) fail "output carries terminal controls (ESC or CR)" ;;
  esac
}

sgr_codes() {
  printf '%s' "$1" \
    | { LC_ALL=C grep -o "$ESC\\[[0-9;]*m" || true; } \
    | LC_ALL=C tr -cd '0-9;\n' \
    | LC_ALL=C sort -u
}

assert_styles_only() {
  local out="$1"; shift
  local allowed=" $* " code seen=""
  while IFS= read -r code; do
    [[ -z "$code" ]] && continue
    seen="$seen $code"
    case "$allowed" in *" $code "*) ;; *) fail "unexpected style $code; allowed:$allowed" ;; esac
  done <<EOF
$(sgr_codes "$out")
EOF
  [[ -n "$seen" ]] || fail "forced color produced no styles at all (allowed:$allowed)"
}
assert_style() { sgr_codes "$1" | { grep -qx "$2" || fail "missing style $2 (have:$(sgr_codes "$1" | tr '\n' ' '))"; } }
assert_no_style() { sgr_codes "$1" | { grep -qx "$2" && fail "unexpected style $2" || true; } }

# strip_ansi STRING: remove SGR sequences so assertions see the glyphs a
# terminal would show, with color forced on.
strip_ansi() {
  printf '%s' "$1" | LC_ALL=C sed "s/${ESC}\\[[0-9;]*m//g"
}

# run_color INPUT FUNC...: pipe INPUT through FUNC with color forced on.
run_color() {
  local input="$1"
  shift
  (export AGENT_RUN_COLOR=always; printf '%s\n' "$input" | "$@")
}

# ---------------------------------------------------------------- header ----

header_json() {
  printf '%s\n' '{"id":"20250920-161901-79f86825","agent":"pi",
    "label":"Design the presentation layer","cwd":"'"$HOME"'/Code/my-project",
    "dir":"'"$HOME"'/.factory-runs/20250920-161901-79f86825",
    "model_requested":"zai/glm-5.3","model_source":"settings"}'
}

header_plain="$(header_json | agent_present_header)"
assert_no_ansi "$header_plain"
assert_has "$header_plain" "Design the presentation layer"
assert_has "$header_plain" "pi"
assert_has "$header_plain" "20250920-161901-79f86825"
assert_has "$header_plain" ".factory-runs/20250920-161901-79f86825"
assert_has "$header_plain" "requested"
assert_has "$header_plain" "zai/glm-5.3"
assert_has "$header_plain" "Code/my-project"

# Headers are framed by horizontal rules so runs read as cards.
rule_first="$(printf '%s' "$header_plain" | head -n 1)"
rule_last="$(printf '%s' "$header_plain" | tail -n 1)"
case "$rule_first" in *"─"*) ;; *) fail "header must open with a horizontal rule" ;; esac
case "$rule_last" in *"─"*) ;; *) fail "header must close with a horizontal rule" ;; esac

# The rule is width-bounded: it follows COLUMNS, clamped to 40..120, and an
# unset or malformed COLUMNS falls back to 80. Measured on the rendered
# opening rule with the glyph folded to ASCII so the count is locale-proof.
rule_cols() {  # rule_cols COLUMNS-value|unset -> character width of the opening rule
  local out
  if [[ "$1" == unset ]]; then
    out="$(unset COLUMNS; agent_present_header <<<'{"id":"20250920-161901-79f86825","agent":"pi","cwd":"/tmp","dir":"/tmp/runs/x"}')"
  else
    out="$(COLUMNS="$1" agent_present_header <<<'{"id":"20250920-161901-79f86825","agent":"pi","cwd":"/tmp","dir":"/tmp/runs/x"}')"
  fi
  out="${out%%$'\n'*}"
  out="${out//─/-}"
  printf '%s' "${#out}"
}
[[ "$(rule_cols unset)" == 80 ]] || fail "rule must default to 80 columns, got $(rule_cols unset)"
[[ "$(rule_cols 100)" == 100 ]] || fail "rule must follow COLUMNS=100, got $(rule_cols 100)"
[[ "$(rule_cols 500)" == 120 ]] || fail "rule must clamp COLUMNS=500 to 120, got $(rule_cols 500)"
[[ "$(rule_cols 10)" == 40 ]] || fail "rule must clamp COLUMNS=10 to 40, got $(rule_cols 10)"
[[ "$(rule_cols abc)" == 80 ]] || fail "malformed COLUMNS must fall back to 80, got $(rule_cols abc)"

# No explicit model: the header must say so, never invent an actual model.
header_default="$(printf '%s\n' '{"id":"20250920-161901-79f86825","agent":"grok",
  "label":"Brief two","cwd":"/tmp","dir":"/tmp/runs/x",
  "model_requested":null,"model_source":null}' | agent_present_header)"
assert_has "$header_default" "default"
assert_lacks "$header_default" "glm"
assert_no_ansi "$header_default"

# Auto on a pipe is plain.
header_auto="$( (unset AGENT_RUN_COLOR; header_json | agent_present_header) )"
assert_no_ansi "$header_auto"

# NO_COLOR wins even over an explicit color request.
header_nocolor="$( (export NO_COLOR=1 AGENT_RUN_COLOR=always; header_json | agent_present_header) )"
assert_no_ansi "$header_nocolor"

# Forced color stays inside the quiet palette: cyan heading, dim metadata.
header_color="$(run_color "$(header_json)" agent_present_header)"
case "$header_color" in *"${ESC}["*"m"*) ;; *) fail "forced header color has no escape sequences" ;; esac
assert_styles_only "$header_color" 0 2 36
assert_style "$header_color" 36

# Malicious label content is neutralized before styling, text preserved.
# The JSON carries \u escapes; jq decodes them, then the layer strips them.
header_evil="$(printf '%s\n' '{"id":"20250920-161901-79f86825","agent":"pi",
  "label":"fix \u001b[2J\u001b]0;pwn\u0007the \rbug","cwd":"/tmp","dir":"/tmp",
  "model_requested":null,"model_source":null}' | agent_present_header)"
assert_no_ansi "$header_evil"
assert_has "$header_evil" "fix the bug"

# Multiple JSON documents are rejected, not joined.
header_multi_rc=0
printf '%s' '{"id":"a","agent":"pi"}{"id":"b","agent":"grok"}' \
  | agent_present_header >"$TMP/hm.out" 2>"$TMP/hm.err" || header_multi_rc=$?
if [[ "$header_multi_rc" -eq 0 ]]; then
  fail "header must reject multiple JSON documents"
fi
assert_lacks "$(cat "$TMP/hm.out")" "grok"

# Non-scalar label is not dumped.
header_obj="$(printf '%s\n' '{"id":"20250920-161901-79f86825","agent":"pi",
  "label":{"nested":"SECRET-LABEL-OBJECT"},"cwd":"/tmp","dir":"/tmp"}' | agent_present_header)"
assert_lacks "$header_obj" "SECRET-LABEL-OBJECT"

# ---------------------------------------------------------------- stream ----

stream_input='[tool] read lib/run-record.sh
[done] read
[error] bash: fixture exited 1
[warn] roster fallback in use
This paragraph is assistant output and must survive verbatim.'
stream_plain="$(printf '%s\n' "$stream_input" | agent_present_stream)"
assert_no_ansi "$stream_plain"
assert_has "$stream_plain" "read lib/run-record.sh"
assert_has "$stream_plain" "bash: fixture exited 1"
assert_has "$stream_plain" "roster fallback in use"
assert_has "$stream_plain" "This paragraph is assistant output and must survive verbatim."
case "$stream_plain" in *"✓ read"*) ;; *) fail "UTF-8 default must use the check mark for [done] read" ;; esac
case "$stream_plain" in *"✗ bash"*) ;; *) fail "UTF-8 default must use the cross for [error]" ;; esac
case "$stream_plain" in *"✓"*"✗"*) ;; *) fail "success and error must be visually distinct" ;; esac

# Tool activity reads as bordered cards with air between them; notes carry a
# side border. Glyphs come from the library's box set, content is unchanged.
assert_has "$stream_plain" "┌─ "
assert_has "$stream_plain" "└─ "
assert_has "$stream_plain" "│ ! roster fallback in use"
case "$stream_plain" in *"┌─ "*"└─ "*) ;; *) fail "tool open must precede its bordered close" ;; esac
think_plain="$(printf '%s\n' '[think]' | agent_present_stream)"
assert_has "$think_plain" "── "
assert_has "$think_plain" "think"

# A closer only answers an opener: a run-level error with no card open takes
# the side border, while a parallel batch closes every card it opened.
orphan_error="$(printf '%s\n' '[error] result error_max_turns' | agent_present_stream)"
[[ "$orphan_error" == "│ ✗ result error_max_turns" ]] || fail "unpaired [error] must take the side border, got: $orphan_error"
batch_plain="$(printf '%s\n' '[tool] Read a' '[tool] Read b' '[done] Read' '[done] Read' | agent_present_stream)"
[[ "$(printf '%s\n' "$batch_plain" | grep -c '^└─ ✓ Read$')" == 2 ]] || fail "each opened card must get its own closer, got: $batch_plain"
assert_lacks "$batch_plain" "│ ✓"
after_batch="$(printf '%s\n' '[tool] Read a' '[done] Read' '[error] bash: exited 1' | agent_present_stream)"
assert_has "$after_batch" "└─ ✓ Read"
assert_has "$after_batch" "│ ✗ bash: exited 1"

# Air separates a card from any earlier output, plain text included, and
# never precedes the first card.
first_card="$(printf '%s\n' '[tool] read x' '[done] read' | agent_present_stream)"
[[ "$first_card" == $'┌─ · read x\n└─ ✓ read' ]] || fail "first card must open without leading air, got: $first_card"
after_text="$(printf '%s\n' 'Answer' '[tool] read x' | agent_present_stream)"
[[ "$after_text" == $'Answer\n\n┌─ · read x' ]] || fail "card after plain text must get air, got: $after_text"
after_think="$(printf '%s\n' '[note] n' '[think]' | agent_present_stream)"
[[ "$after_think" == $'│ n\n\n── · think' ]] || fail "divider after a label must get air, got: $after_think"

# Assistant text is never truncated or rewrapped.
long_para="P$(printf 'x%.0s' $(seq 1 400))END"
stream_long="$(printf '%s\n' "$long_para" | agent_present_stream)"
assert_has "$stream_long" "$long_para"

# TERM=dumb falls back to ASCII marks even in forced color and a UTF-8 locale.
stream_ascii="$( (export TERM=dumb LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 AGENT_RUN_COLOR=always; printf '[done] read\n' | agent_present_stream) )"
assert_lacks "$stream_ascii" "✓"
assert_has "$(strip_ansi "$stream_ascii")" "+ read"
ascii_box="$( (export TERM=dumb LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 AGENT_RUN_COLOR=never; printf '%s\n' '[tool] read a' '[done] read' '[note] hello' | agent_present_stream) )"
assert_has "$ascii_box" "+- "
assert_has "$ascii_box" "| hello"

# An explicit UTF-8 locale plus a non-dumb TERM yields unicode marks even
# when the caller started as TERM=dumb.
stream_utf8="$( (export TERM=xterm LC_ALL=C.UTF-8 LANG=C.UTF-8; printf '[done] read\n' | agent_present_stream) )"
assert_has "$stream_utf8" "✓ read"

# Forced color emits only the documented stream palette.
stream_color="$(run_color "$stream_input" agent_present_stream)"
assert_styles_only "$stream_color" 0 2 31 32 33

# Control characters in streamed lines are stripped, content kept.
stream_evil="$(printf '[tool] \033[2J\033[1;31mrm -rf /\033]0;t\007 value\rafter\n' | agent_present_stream)"
assert_no_ansi "$stream_evil"
assert_has "$stream_evil" "rm -rf /"
assert_has "$stream_evil" "value"
assert_has "$stream_evil" "after"

# Standalone C0/DEL (BEL, BS, FF, DEL) must not pass through; tabs stay.
stream_c0="$(printf 'keep\tme\007\010\014\177end\n' | agent_present_stream)"
assert_has "$stream_c0" $'keep\tme'
assert_has "$stream_c0" "end"
c0_hex="$(printf '%s' "$stream_c0" | LC_ALL=C od -An -tx1)"
case " $c0_hex " in
  *" 07 "*|*" 08 "*|*" 0c "*|*" 7f "*) fail "stream leaked C0/DEL bytes: $c0_hex" ;;
esac

# Incremental: the first line is rendered before stdin closes.
fifo="$TMP/in.fifo"
stream_out="$TMP/stream.out"
mkfifo "$fifo"
( agent_present_stream <"$fifo" >"$stream_out" ) &
reader=$!
exec 3>"$fifo"
printf '%s\n' '[tool] read README.md' >&3
stream_seen=""
deadline=$((SECONDS + 5))
while (( SECONDS < deadline )); do
  if has "$(cat "$stream_out" 2>/dev/null || true)" "read README.md"; then stream_seen=1; break; fi
  sleep 0.1
done
[[ -n "$stream_seen" ]] || fail "first streamed line did not appear before stdin closed"
kill -0 "$reader" 2>/dev/null || fail "stream reader exited before stdin closed"
exec 3>&-
stream_deadline=$((SECONDS + 5))
while kill -0 "$reader" 2>/dev/null && (( SECONDS < stream_deadline )); do sleep 0.1; done
if kill -0 "$reader" 2>/dev/null; then
  kill "$reader" 2>/dev/null || true
  wait "$reader" 2>/dev/null || true
  fail "stream did not exit at EOF within 5s"
fi
wait "$reader" || fail "stream exited nonzero at EOF"

# Newline-free assistant text is visible before EOF.
partial_fifo="$TMP/partial.fifo"
partial_out="$TMP/partial.out"
mkfifo "$partial_fifo"
: > "$partial_out"
( agent_present_stream <"$partial_fifo" >"$partial_out" ) &
partial_reader=$!
exec 4>"$partial_fifo"
printf '%s' 'short progress' >&4
partial_seen=""
partial_deadline=$((SECONDS + 5))
while (( SECONDS < partial_deadline )); do
  if has "$(cat "$partial_out" 2>/dev/null || true)" "short progress"; then partial_seen=1; break; fi
  sleep 0.1
done
[[ -n "$partial_seen" ]] || fail "newline-free progress did not appear before stdin closed"
exec 4>&-
wait "$partial_reader" || fail "partial stream exited nonzero at EOF"

# ---------------------------------------------------------------- record ----

record_json() {
  local state="$1" exit_code="$2" capture="$3" capture_exit="$4" receipt="$5" native="$6" label="$7" problems="$8"
  printf '%s\n' '{"id":"20250920-161901-79f86825",
    "dir":"'"$TMP"'/runs/20250920-161901-79f86825",
    "state":"'"$state"'","exit":'"${exit_code-null}"',
    "capture":'"${capture-null}"',"capture_exit":'"${capture_exit-null}"',
    "agent":"pi","binary":"pi","mode":"edit","project":"my-project",
    "cwd":"'"$HOME"'/Code/my-project","worktree":null,"branch":null,
    "lease_id":null,"tab_id":null,"pane_id":null,
    "label":'"${label-null}"',"created":"2026-09-20T16:19:01Z",
    "base_sha":null,"model_requested":"zai/glm-5.3","model_source":"settings",
    "purpose":"implementation","depth":0,"caller_agent":null,"caller_session":null,
    "parent_run":null,"wrapper_sha":null,"wrapper_dirty":false,
    "native_adapter":"pi","native_session_id":"00000000-0000-0000-0000-000000000000",
    "native":'"$native"',
    "startup":null,"receipt":'"${receipt-null}"',
    "paths":{"meta":"'"$TMP"'/runs/20250920-161901-79f86825/meta.json",
             "brief":"'"$TMP"'/runs/20250920-161901-79f86825/brief.md",
             "log":"'"$TMP"'/runs/20250920-161901-79f86825/log.txt",
             "exit":null,"capture":null},
    "problems":'"$problems"'}'
}

# Completed: process completed, receipt advisory, never "accepted".
rec_done="$(record_json completed 0 '"complete"' 0 '"present"' \
  '{"adapter":"pi","id":"s1","found":true,"store":"/s","started_at":null,"last_activity":null,
    "model":null,"terminal":"completed","stop_reason":null,"cancellation":null,
    "permission_tool":null,"final_text":null}' '"Design the presentation layer"' '[]' | agent_present_record)"
assert_no_ansi "$rec_done"
assert_has "$rec_done" "completed"
assert_has "$rec_done" "exit 0"
assert_has "$rec_done" "requested: zai/glm-5.3"
assert_has "$rec_done" "review"
assert_has "$rec_done" "verify"
assert_lacks "$rec_done" "accepted"
assert_has "$rec_done" "runs/20250920-161901-79f86825/log.txt"
assert_lacks "$rec_done" "tail -f"

# Failure reads differently at a glance.
rec_failed="$(record_json failed 3 '"complete"' 0 null 'null' null '[]' | agent_present_record)"
assert_no_ansi "$rec_failed"
assert_has "$rec_failed" "failed"
assert_has "$rec_failed" "exit 3"
assert_lacks "$rec_failed" "review"

# Capture failure: the log is not trusted even though the process exited 0.
rec_capture="$(record_json incomplete 0 '"failed"' 1 null 'null' null '[]' | agent_present_record)"
assert_no_ansi "$rec_capture"
assert_has "$rec_capture" "incomplete"
assert_has "$rec_capture" "capture"
assert_has "$rec_capture" "truncated"

# Open record: liveness unknown, follow by run id, usable log path, no tail -f
# and no claim that the log is still growing.
rec_open="$(record_json open null null null null 'null' '"Long brief"' '[]' | agent_present_record)"
assert_no_ansi "$rec_open"
assert_has "$rec_open" "open"
assert_has "$rec_open" "unknown"
assert_has "$rec_open" "agent-run --follow 20250920-161901-79f86825"
assert_has "$rec_open" "runs/20250920-161901-79f86825/log.txt"
assert_lacks "$rec_open" "tail -f"
assert_lacks "$rec_open" "still being written"
assert_lacks "$rec_open" "growing"
assert_lacks "$rec_open" "completed"

# Unknown evidence stays visibly unknown: v1 record without capture, no native.
rec_unknown="$(record_json completed 0 '"unknown"' null null 'null' null '[]' | agent_present_record)"
assert_no_ansi "$rec_unknown"
assert_has "$rec_unknown" "unknown"
assert_lacks "$rec_unknown" "terminal:"

# A cancelled native turn is never presented as a completed task.
rec_cancelled="$(record_json cancelled 0 '"complete"' 0 null \
  '{"adapter":"grok","id":"s2","found":true,"store":"/s","started_at":null,"last_activity":null,
    "model":null,"terminal":"cancelled","stop_reason":null,"cancellation":"user",
    "permission_tool":null,"final_text":null}' null '[]' | agent_present_record)"
assert_has "$rec_cancelled" "cancelled"

# Killed: the recorded pane is proven gone by a live snapshot; no exit marker
# can ever appear, so the record points at --output instead of --follow.
rec_killed="$(record_json killed null null null null 'null' null '[]' | agent_present_record)"
assert_no_ansi "$rec_killed"
assert_has "$rec_killed" "killed"
assert_has "$rec_killed" "recorded pane no longer exists"
assert_has "$rec_killed" "agent-run --output"
assert_lacks "$rec_killed" "agent-run --follow"

# A stop receipt renders as one line: when, why, and where it got to.
rec_stopped="$(record_json killed null null null null 'null' null '[]' \
  | jq --arg at "2026-09-23T21:42:00Z" --arg reason "race-loser" --arg note "last output: chunk 3; worktree preserved" \
    '. + {stopped:{at:$at,reason:$reason,note:$note}}' \
  | agent_present_record)"
assert_no_ansi "$rec_stopped"
assert_has "$rec_stopped" "stopped 2026-09-23T21:42:00Z (race-loser): last output: chunk 3; worktree preserved"
assert_has "$rec_stopped" "killed"

# Invalid record shows its problems.
rec_invalid="$(record_json invalid null null null null 'null' null \
  '["meta.json is a symlink"]' | agent_present_record)"
assert_has "$rec_invalid" "invalid"
assert_has "$rec_invalid" "meta.json is a symlink"

# Native evidence named but not found stays unknown. found=false wins over a
# leftover terminal field.
rec_natmissing="$(record_json open null null null null \
  '{"adapter":"pi","id":"s3","found":false,"store":null,"started_at":null,"last_activity":null,
    "model":null,"terminal":"completed","stop_reason":null,"cancellation":null,
    "permission_tool":null,"final_text":null}' null '[]' | agent_present_record)"
assert_has "$rec_natmissing" "unknown"
assert_lacks "$rec_natmissing" "terminal: completed"
assert_lacks "$rec_natmissing" "terminal:completed"

# Explicit empty native object claims nothing, including found=false without
# an adapter name.
rec_natzero="$(record_json completed 0 '"complete"' 0 '"present"' \
  '{"found":false}' null '[]' | agent_present_record)"
assert_lacks "$rec_natzero" "terminal:"
assert_lacks "$rec_natzero" "session store not found"

# Forced palettes separate the headline outcomes.
rec_done_color="$(run_color "$(record_json completed 0 '"complete"' 0 '"present"' 'null' null '[]')" agent_present_record)"
assert_styles_only "$rec_done_color" 0 2 32 36
assert_style "$rec_done_color" 32
rec_failed_color="$(run_color "$(record_json failed 3 '"complete"' 0 null 'null' null '[]')" agent_present_record)"
assert_styles_only "$rec_failed_color" 0 2 31 36
assert_style "$rec_failed_color" 31
rec_capture_color="$(run_color "$(record_json incomplete 0 '"failed"' 1 null 'null' null '[]')" agent_present_record)"
assert_styles_only "$rec_capture_color" 0 2 33 36
assert_style "$rec_capture_color" 33

# Multiple documents rejected for record too.
rec_multi_rc=0
printf '%s' '{"id":"a","state":"completed"}{"id":"b","state":"failed"}' \
  | agent_present_record >"$TMP/rm.out" 2>"$TMP/rm.err" || rec_multi_rc=$?
if [[ "$rec_multi_rc" -eq 0 ]]; then
  fail "record must reject multiple JSON documents"
fi

# Path with a space stays whole and usable.
rec_space="$(printf '%s\n' '{"id":"20250920-161901-79f86825","dir":"'"$TMP"'/runs/spaced dir",
  "state":"completed","exit":0,"capture":"complete","agent":"pi","label":"Spaced",
  "native":null,"receipt":"present","paths":{"log":"'"$TMP"'/runs/spaced dir/log.txt"},
  "problems":[]}' | agent_present_record)"
assert_has "$rec_space" "spaced dir/log.txt"

# ------------------------------------------------------------------ goal ----

goal_attention='{"id":"goal-20260920-161901-abc12345","title":"Ship the goal flow",
  "state":"attention","dir":"'"$TMP"'/runs/.goals/goal-20260920-161901-abc12345",
  "tasks":[
    {"id":"implement","agent":"pi","state":"completed",
     "run":{"id":"20260920-161901-11111111","state":"completed","exit":0,
            "paths":{"log":"'"$TMP"'/runs/20260920-161901-11111111/log.txt"},
            "native_terminal":null}},
    {"id":"research","agent":"pi","state":"open",
     "run":{"id":"20260920-161901-22222222","state":"open","exit":null,
            "paths":{"log":"'"$TMP"'/runs/20260920-161901-22222222/log.txt"},
            "native_terminal":null}},
    {"id":"docs","agent":"cursor","state":"launch_failed",
     "run":null,"failure":{"message":"herdr tab create failed: pane budget exhausted"}},
    {"id":"plan","agent":"pi","status":"not_started","run":null}
  ],
  "counts":{"planned":4,"not_started":1,"open":1,"completed":1,"failed":0,
            "cancelled":0,"incomplete":0,"invalid":0,"launch_failed":1},
  "problems":["worker extra is not in the plan"]}'

goal_plain="$(printf '%s\n' "$goal_attention" | agent_present_goal)"
assert_no_ansi "$goal_plain"
assert_has "$goal_plain" "Ship the goal flow"
assert_has "$goal_plain" "attention"
for task in implement research docs plan; do assert_has "$goal_plain" "$task"; done
assert_has "$goal_plain" "cursor"
assert_has "$goal_plain" "herdr tab create failed: pane budget exhausted"
assert_has "$goal_plain" "runs/20260920-161901-11111111/log.txt"
assert_has "$goal_plain" "agent-run --follow 20260920-161901-22222222"
assert_has "$goal_plain" "runs/20260920-161901-22222222/log.txt"
assert_lacks "$goal_plain" "tail -f"
assert_has "$goal_plain" "worker extra is not in the plan"
# An open run means liveness unknown, never "running strong".
assert_has "$goal_plain" "liveness unknown"

# Ownership and briefs appear on the wired proposal view.
goal_proposal="$(printf '%s\n' '{"id":"goal-20260920-161904-abc12345","title":"Split the library",
  "state":"proposal_ready","dir":"'"$TMP"'/runs/.goals/goal-20260920-161904-abc12345",
  "tasks":[
    {"id":"alpha","agent":"pi","state":"not_started","brief":"write the validator",
     "owns":["lib/goal-record.sh"],"run":null},
    {"id":"beta","agent":"cursor","status":"not_started","brief":"write the tests",
     "owns":["tests/goal-record.test.sh"],"run":null}
  ]}' | agent_present_goal)"
assert_has "$goal_proposal" "proposal ready"
assert_has "$goal_proposal" "write the validator"
assert_has "$goal_proposal" "lib/goal-record.sh"
assert_has "$goal_proposal" "agent-run --goal-start goal-20260920-161904-abc12345"
assert_lacks "$goal_proposal" "accepted"

# Completed goal work is ready for review, never accepted.
goal_review="$(printf '%s\n' '{"id":"goal-20260920-161902-abc12345","title":"Review me",
  "state":"needs_review","dir":"'"$TMP"'/runs/.goals/goal-20260920-161902-abc12345",
  "tasks":[
    {"id":"implement","agent":"pi","state":"completed",
     "run":{"id":"20260920-161901-11111111","state":"completed","exit":0,
            "paths":{"log":"'"$TMP"'/runs/20260920-161901-11111111/log.txt"},
            "native_terminal":"completed"}}
  ]}' | agent_present_goal)"
assert_no_ansi "$goal_review"
assert_has "$goal_review" "needs review"
assert_has "$goal_review" "review worker diffs"
assert_lacks "$goal_review" "state   accepted"

# Goal titles are sanitized too.
goal_evil="$(printf '%s\n' '{"id":"goal-20260920-161903-abc12345","title":"Bad \u001b[31mtitle",
  "state":"planning","dir":"'"$TMP"'/runs/.goals/g3","tasks":[]}' | agent_present_goal)"
assert_no_ansi "$goal_evil"
assert_has "$goal_evil" "title"

# Forced palette stays quiet and states look different.
goal_color="$(run_color "$goal_attention" agent_present_goal)"
assert_styles_only "$goal_color" 0 2 31 32 33 36
assert_style "$goal_color" 33

goal_multi_rc=0
printf '%s' '{"id":"g1","title":"A","state":"planning","tasks":[]}{"id":"g2","title":"B"}' \
  | agent_present_goal >"$TMP/gm.out" 2>"$TMP/gm.err" || goal_multi_rc=$?
if [[ "$goal_multi_rc" -eq 0 ]]; then
  fail "goal must reject multiple JSON documents"
fi

# TERM=dumb + NO_COLOR together stay plain ASCII.
goal_dumb="$( (export TERM=dumb NO_COLOR=1 AGENT_RUN_COLOR=always LC_ALL=en_US.UTF-8;
  printf '%s\n' "$goal_attention" | agent_present_goal) )"
assert_no_ansi "$goal_dumb"
assert_lacks "$goal_dumb" "✓"
assert_has "$goal_dumb" "Ship the goal flow"

# Ordinary bracket text is not a label: exact bytes, no extra EOF newline.
bracket_one="$(printf '%s' '[1]' | agent_present_stream)"
[[ "$bracket_one" == '[1]' ]] || fail "ordinary [1] must be preserved without an extra newline"

# Split CSI must be consumed as a control, not leaked as [31m.
split_csi="$(printf 'x%s[31mred%s[0my' "$ESC" "$ESC" | agent_present_stream)"
[[ "$split_csi" == "xredy" ]] || fail "split CSI must sanitize to xredy, got: $split_csi"
assert_no_ansi "$split_csi"

# Long newline-free text must stay exact and must not require per-byte forks
# to finish (2000 chars through a bash loop is the regression).
long_plain="Q$(printf 'z%.0s' $(seq 1 1998))R"
long_out="$(printf '%s' "$long_plain" | agent_present_stream)"
[[ "$long_out" == "$long_plain" ]] || fail "2000-char plain stream must match exactly"

note_out="$(printf '%s\n' '[note] session id is already set' | AGENT_RUN_RUN=abc123 run=/tmp/rec agent_present_stream)"
grep -q 'session id is already set' <<<"$note_out" || fail "note lines must reach the pane"
grep -q 'agent-run abc123 streaming /tmp/rec/display.txt' <<<"$note_out" || fail "live sink must repeat the run identity"

# ------------------------------------------------------- protocol v2 ----

# Plan rows: one divider for a run of consecutive rows, a mark per state,
# the position always present so nothing depends on color.
plan_out="$(printf '%s\n' '[todo] 1/3 done Read the README' '[todo] 2/3 active Count its lines' '[todo] 3/3 pending Report the count' | agent_present_stream)"
[[ "$plan_out" == $'── · plan\n│ ✓ 1/3 Read the README\n│ ▸ 2/3 Count its lines\n│ · 3/3 Report the count' ]] || fail "plan rows, got: $plan_out"
drop_out="$(printf '%s\n' '[todo] 1/1 dropped Old idea' | agent_present_stream)"
assert_has "$drop_out" "│ – 1/1 Old idea"
split_plan="$(printf '%s\n' '[todo] 1/2 active a' 'Text between' '[todo] 2/2 pending b' | agent_present_stream)"
[[ "$(grep -c '· plan' <<<"$split_plan")" == 2 ]] || fail "a plan row after other output gets its own divider, got: $split_plan"
plan_ascii="$( (export TERM=dumb; printf '%s\n' '[todo] 1/2 done a' '[todo] 2/2 active b' | agent_present_stream) )"
assert_has "$plan_ascii" "| + 1/2 a"
assert_has "$plan_ascii" "| > 2/2 b"
assert_lacks "$plan_ascii" "✓"
plan_color="$(run_color "$(printf '%s\n' '[todo] 1/2 done a' '[todo] 2/2 active b')" agent_present_stream)"
assert_styles_only "$plan_color" 0 2 32 36
bad_plan="$(printf '%s\n' '[todo] 1/1 weird thing' | agent_present_stream)"
assert_has "$bad_plan" "? 1/1 weird thing"

# Waits carry the word "waiting" and the kind; steps read as "now".
wait_out="$(printf '%s\n' '[wait] permission: Write notes.txt (outside the working directory)' | agent_present_stream)"
[[ "$wait_out" == "│ ~ waiting (permission) Write notes.txt (outside the working directory)" ]] || fail "wait line, got: $wait_out"
retry_out="$(printf '%s\n' '[wait] retry 1/3 in 2000ms: rate limited' | agent_present_stream)"
assert_has "$retry_out" "~ waiting (retry) 1/3 in 2000ms: rate limited"
wait_ascii="$( (export TERM=dumb; printf '[wait] compacting context (oversize)\n' | agent_present_stream) )"
[[ "$wait_ascii" == "| ~ waiting (compacting) context (oversize)" ]] || fail "ascii wait, got: $wait_ascii"
wait_color="$(run_color '[wait] permission: Write x' agent_present_stream)"
assert_style "$wait_color" 33
step_out="$(printf '[step] Counting lines with wc\n' | agent_present_stream)"
[[ "$step_out" == "│ now Counting lines with wc" ]] || fail "step line, got: $step_out"

# Run lines: identity dim, success result green, other results amber.
run_out="$(printf '%s\n' '[run] claude claude-opus-5-5 session 3f9c2a71' '[run] result success (4210ms, 3 turns)' '[run] result error_max_turns (1ms, 9 turns)' | agent_present_stream)"
assert_has "$run_out" "│ run claude claude-opus-5-5 session 3f9c2a71"
assert_has "$run_out" "│ ✓ result success (4210ms, 3 turns)"
assert_has "$run_out" "│ ! result error_max_turns (1ms, 9 turns)"
acp_out="$(printf '%s\n' '[run] result end_turn (12400 tokens)' '[run] result refusal (31 tokens)' | agent_present_stream)"
assert_has "$acp_out" "│ ✓ result end_turn (12400 tokens)"
assert_has "$acp_out" "│ ! result refusal (31 tokens)"
run_color_out="$(run_color '[run] result success (1ms, 1 turns)' agent_present_stream)"
assert_style "$run_color_out" 32

# End lines in a replayed display.txt.
end_ok="$(printf '[end] success exit 0 elapsed 12s record /r/x\n' | agent_present_stream)"
[[ "$end_ok" == "── ✓ success exit 0 elapsed 12s record /r/x" ]] || fail "end line, got: $end_ok"
end_bad="$(printf '[end] failed exit 3 elapsed 1s record /r/x\n' | agent_present_stream)"
assert_has "$end_bad" "✗ failed exit 3"
end_color="$(run_color '[end] failed exit 3 elapsed 1s record /r/x' agent_present_stream)"
assert_style "$end_color" 31

# New labels are held like the old ones: no partial "[wa" leaks, and a
# bracket word that is not a label still passes through whole.
mixed="$(printf '%s\n' '[wait] x' '[steps] not a label' '[running] either' | agent_present_stream)"
assert_has "$mixed" "~ waiting (x)"
assert_has "$mixed" "[steps] not a label"
assert_has "$mixed" "[running] either"
eof_label="$(printf '[todo] 1/1 active tail' | agent_present_stream)"
assert_has "$eof_label" "▸ 1/1 tail"

# Control bytes inside the new labels are stripped like everywhere else.
evil_plan="$(printf '[todo] 1/1 active \033[2Jrm\007 -rf\n[wait] permission: \033]0;x\007Write\n' | agent_present_stream)"
assert_no_ansi "$evil_plan"
assert_has "$evil_plan" "rm -rf"
assert_has "$evil_plan" "Write"

# ---------------------------------------------------- context header ----

ctx_json='{"id":"20261004-050000-ab12cd34","agent":"claude","project":"agent-stream","branch":"main",
  "task":"Rethink and rebuild how this repository shows a headless coding agent at work in a terminal pane.\nSecond paragraph.",
  "cwd":"/home/me/Code/agent-stream","dir":"/home/me/.agent-stream/runs/20261004-050000-ab12cd34","model_requested":null}'
ctx="$(printf '%s\n' "$ctx_json" | agent_present_header)"
assert_no_ansi "$ctx"
assert_has "$ctx" "▸ agent-stream · main"
assert_has "$ctx" "task    Rethink and rebuild how this repository shows a headless coding agent…"
assert_lacks "$ctx" "Second paragraph"
assert_lacks "$ctx" "terminal pane."
assert_has "$ctx" "run     20261004-050000-ab12cd34 · claude"
assert_has "$ctx" "requested: none"
ctx_wide="$(COLUMNS=120 agent_present_header <<<"$ctx_json")"
assert_has "$ctx_wide" "at work in a terminal pane. Second"
ctx_label="$(printf '%s\n' '{"id":"x1","agent":"pi","label":"Only a label","project":"demo","cwd":"/t","dir":"/t"}' | agent_present_header)"
assert_has "$ctx_label" "▸ demo"
assert_has "$ctx_label" "task    Only a label"
ctx_evil="$(printf '%s\n' '{"id":"x1","agent":"pi","project":"p\u001b[2J","branch":"b\u0007","task":"t\rx","cwd":"/t","dir":"/t"}' | agent_present_header)"
assert_no_ansi "$ctx_evil"
assert_has "$ctx_evil" "▸ p · b"
ctx_color="$(run_color "$ctx_json" agent_present_header)"
assert_styles_only "$ctx_color" 0 2 36

# ------------------------------------------------------- ending card ----

end_json() {
  printf '%s\n' '{"outcome":{"kind":"'"$1"'","exit":'"$2"',"summary":'"$3"'},"elapsed_s":'"$4"',
    "todo_counts":{"done":3,"total":3},"counts":{"tools":12,"errors":'"$5"'},
    "last_error":"Bash: make: *** [test] Error 1","task":"Count the lines",
    "record":{"dir":"'"$HOME"'/.agent-stream/runs/20261004-050000-ab12cd34"}}'
}
end_done="$(end_json success 0 '"README.md: 3 lines"' 252 1 | agent_present_end)"
assert_no_ansi "$end_done"
assert_has "$end_done" "✓ done · exit 0 · 4m12s · plan 3/3 done · 12 tools, 1 error"
assert_has "$end_done" "summary README.md: 3 lines"
assert_has "$end_done" "task    Count the lines"
assert_has "$end_done" "record  ~/.agent-stream/runs/20261004-050000-ab12cd34/"
assert_lacks "$end_done" "Error 1"
assert_lacks "$end_done" "accepted"
rule_first="$(printf '%s' "$end_done" | head -n 1)"
case "$rule_first" in *"─"*) ;; *) fail "ending must open with a horizontal rule" ;; esac
end_failed="$(end_json failed 3 null 42 2 | agent_present_end)"
assert_has "$end_failed" "✗ failed · exit 3 · 42s · plan 3/3 done · 12 tools, 2 errors"
assert_has "$end_failed" "error   Bash: make: *** [test] Error 1"
assert_lacks "$end_failed" "summary"
end_error="$(end_json error 0 null 3700 0 | agent_present_end)"
assert_has "$end_error" "✗ failed · exit 0 but the harness reported an error · 1h01m"
end_cancel="$(end_json cancelled 0 null 5 0 | agent_present_end)"
assert_has "$end_cancel" "! cancelled · exit 0"
end_exited="$(end_json exited 0 null 5 0 | agent_present_end)"
assert_has "$end_exited" "· exited · exit 0"
end_min="$(printf '%s\n' '{"status":"ended"}' | agent_present_end)"
assert_has "$end_min" "? ended"
end_colors="$(run_color "$(end_json success 0 null 1 0)" agent_present_end)"
assert_styles_only "$end_colors" 0 2 32
assert_style "$end_colors" 32
end_fail_colors="$(run_color "$(end_json failed 1 null 1 1)" agent_present_end)"
assert_style "$end_fail_colors" 31
end_evil="$(printf '%s\n' '{"outcome":{"kind":"success","exit":0,"summary":"ok \u001b[31mred"},"record":{"dir":"/r\u0007"}}' | agent_present_end)"
assert_no_ansi "$end_evil"
assert_has "$end_evil" "summary ok red"
end_multi_rc=0
printf '%s' '{"outcome":{}}{"outcome":{}}' | agent_present_end >/dev/null 2>&1 || end_multi_rc=$?
[[ "$end_multi_rc" -ne 0 ]] || fail "end must reject multiple JSON documents"

# ------------------------------------------------------- status card ----

SR="$TMP/staterec"
mkdir -p "$SR"
printf '%s\n' '{"status":"running","started_at":"2020-01-01T00:00:00Z","project":{"name":"demo","branch":"main"},
  "todo_counts":{"done":1,"total":3},"todos":[{"n":2,"text":"Count its lines","status":"active"}],
  "activity":{"kind":"tool","text":"Bash make test"},"counts":{"tools":12,"errors":1},"waiting":null,"step":null}' >"$SR/state.json"
many="$(for i in $(seq 1 41); do printf 'line %s\n' "$i"; done | run="$SR" agent_present_stream)"
card="$(grep '· plan 1/3' <<<"$many" || true)"
[[ -n "$card" ]] || fail "a status card must appear every 40 lines when a record is set: $(tail -n 3 <<<"$many")"
case "$card" in "── "*"demo main · plan 1/3: Count its lines · now Bash make test · 12 tools, 1 error"*) ;; *) fail "status card content, got: $card" ;; esac
[[ "$(grep -c '· plan 1/3' <<<"$many")" == 1 ]] || fail "exactly one card in 41 lines"
assert_lacks "$(head -n 2 <<<"$many")" "plan 1/3"
printf '%s\n' '{"status":"waiting","started_at":"2020-01-01T00:00:00Z","waiting":{"kind":"permission","text":"Write x"},"counts":{"tools":1,"errors":0},"todo_counts":{"done":0,"total":0}}' >"$SR/state.json"
waiting_many="$(for i in $(seq 1 41); do printf 'line %s\n' "$i"; done | run="$SR" agent_present_stream)"
assert_has "$waiting_many" "waiting permission Write x · 1 tool"
no_state="$(for i in $(seq 1 41); do printf 'line %s\n' "$i"; done | run="$TMP/nowhere" agent_present_stream)"
assert_lacks "$no_state" "── "
[[ "$(wc -l <<<"$no_state" | tr -d ' ')" == 41 ]] || fail "no state file means no card and no extra lines"

# Pinned mode never emits controls when stdout is not a terminal.
pinned_pipe="$( (export AGENT_RUN_STATUS=pinned; printf '%s\n' '[tool] read a' '[done] read' | run="$SR" agent_present_stream) )"
assert_no_ansi "$pinned_pipe"
assert_has "$pinned_pipe" "✓ read"

echo "agent-present tests: all passed"
