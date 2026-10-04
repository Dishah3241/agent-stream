#!/usr/bin/env bash
set -euo pipefail

# Themes in the pane (lib/agent-theme.sh): the base look is untouched
# wherever a theme must not apply, each shipped design renders its own
# words and glyphs, colors use the theme's own fallbacks per depth,
# callsigns match the watcher's, a project's .agent-stream/ folder picks the
# theme, eggs fire only on real conditions and only when allowed, and the
# record never changes with the theme.

fail() { echo "agent-theme test: ${*:-assertion failed at line ${BASH_LINENO[0]}}" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A UTF-8 locale the system has; themes only apply on UTF-8 terminals.
export LC_ALL=C.UTF-8 LANG=C.UTF-8
for _l in en_US.UTF-8 C.UTF-8 en_US.utf8; do
  if [[ -z "$(LC_ALL=$_l bash -c ':' 2>&1)" ]]; then export LC_ALL="$_l" LANG="$_l"; break; fi
done
export TERM=xterm-256color COLUMNS=76
unset NO_COLOR AGENT_STREAM_THEME AGENT_STREAM_LOUDNESS AGENT_STREAM_EGGS AGENT_STREAM_THEMES COLORTERM AGENT_RUN_RUN run
# Run from a directory with no project config, so only the test decides.
cd "$TMP"
export AGENT_STREAM_PROJECT_DIR="$TMP"

# shellcheck source=../lib/agent-present.sh
source "$ROOT/lib/agent-present.sh"

strip() { LC_ALL=C sed $'s/\033\\[[0-9;]*m//g'; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

STREAM=$'[run] claude claude-opus-5-5 session 3f9c2a71\n[todo] 1/3 done Load\n[todo] 2/3 active Integrate\n[todo] 3/3 pending Report\n[tool] Bash make\n[done] Bash\n[tool] Bash a\n[error] Bash: diverged\n[tool] Bash b\n[error] Bash: diverged\n[tool] Bash c\n[error] Bash: diverged\n[wait] permission: Write results.csv\n[step] counting\n[warn] slow\n[think]\nreasoning\nConverged.\n[run] result success (4210ms, 3 turns, 1 denied)'
END_JSON='{"id":"20261004-050000-ab12cd34","agent":"claude","task":"Integrate","outcome":{"kind":"success","exit":0,"summary":"converged"},"elapsed_s":9000,"todo_counts":{"done":3,"total":3},"counts":{"tools":42,"errors":3},"record":{"dir":"/r/x"}}'
HEADER_JSON='{"id":"20261004-050000-ab12cd34","agent":"claude","project":"forge","branch":"main","task":"Integrate the model","cwd":"/w","dir":"/r/x"}'

pane() {  # pane THEME ENV...: stream, header, and ending through the presenter
  local theme="$1"; shift
  (
    export AGENT_STREAM_THEME="$theme" AGENT_RUN_COLOR=always "$@"
    printf '%s\n' "$HEADER_JSON" | agent_present_header
    printf '%s\n' "$STREAM" | agent_present_stream
    printf '%s\n' "$END_JSON" | agent_present_end
  ) 2>"$TMP/pane.err"
}

# ------------------------------------------------- the base stays the base --

base="$(pane plain)"
for env in "NO_COLOR=1" "TERM=dumb" "AGENT_STREAM_LOUDNESS=quiet" "AGENT_RUN_COLOR=never"; do
  # Each condition must give exactly what the base gives under it.
  want="$(pane plain "$env")"
  got="$(pane space "$env")"
  [[ "$got" == "$want" ]] || fail "space under $env must be the base look"
done
got="$(LC_ALL=C pane space)"
want="$(LC_ALL=C pane plain)"
[[ "$got" == "$want" ]] || fail "a non-UTF-8 locale must get the base look"
base_text="$(printf '%s' "$base" | strip)"
has "$base_text" "── · plan" || fail "the base plan divider is unchanged"
has "$base_text" "│ ~ waiting (permission) Write results.csv" || fail "the base wait line is unchanged"
has "$base_text" "✓ done · exit 0" || fail "the base ending is unchanged"
! has "$base_text" "altitude" || fail "the base draws no gauge"

# ------------------------------------------------------- the five designs --

check_theme() {  # check_theme NAME WORD...
  local name="$1" out; shift
  out="$(pane "$name" | strip)"
  for w in "$@"; do has "$out" "$w" || fail "$name must render: $w"$'\n'"$out"; done
}
check_theme space "▲ ignition claude" "· flight plan" "✦ 1/3 Load" "➤ 2/3 Integrate" "✦━━➤┈┈·  altitude 1/3" \
  "burn Bash make" "✓ Bash nominal" "✗ anomaly Bash: diverged" "~ holding (permission)" "heading counting" \
  "! caution slow" "plotting course" "MECO result success" "T-0    ▲ liftoff" "MISSION REPORT" "ORBIT ACHIEVED  success · exit 0 · 2h30m" \
  "42 burns, 3 anomalies" "recorder  /r/x/"
check_theme observatory "◐ dome open" "· observing plan" "exposure Bash make" "frame saved" "cloud cover" \
  "~ tracking (permission)" "OBSERVING LOG" "DAWN: PLATES DEVELOPED" "developed 3/3"
check_theme blueprint "· drawing set" "draft Bash make" "inked" "redline" "awaiting sign-off" "|<" "1 of 3" "TITLE BLOCK" "APPROVED FOR CONSTRUCTION"
check_theme radio "◉ on air claude" "· rundown" "segment Bash make" "wrapped" "dead air" "holding for caller" "SHOW LOG" "SIGNING OFF" "♪──●··"
check_theme bottling "line started" "· batch sheet" "fill Bash make" "capped" "spill" "line paused" "BATCH REPORT" "SHIPPED" "▕●●●●○"

# AGENT_RUN_COLOR=always is the 16-color palette, as in the watcher.
out="$(pane space)"
has "$out" $'\033[36m' || fail "forced color uses the theme's 16-color accent"
! has "$out" "38;5;" || fail "forced color never uses 256 colors"
! has "$out" "38;2;" || fail "forced color never uses true color"

# Depth picks the theme's own fallback, not a computed one.
depth_of() { jq -r --arg depth "$1" -f "$ROOT/lib/agent-theme.jq" "$ROOT/themes/space.json" | grep '^_AP_HEAD='; }
has "$(depth_of tc)" "38;2;92;225;230" || fail "true color uses the hex value: $(depth_of tc)"
has "$(depth_of 256)" "38;5;80" || fail "256 colors use ansi256: $(depth_of 256)"
has "$(depth_of 16)" "[36m" || fail "16 colors use ansi: $(depth_of 16)"
bright="$(jq -r --arg depth 16 -f "$ROOT/lib/agent-theme.jq" "$ROOT/themes/space.json" | grep '^_AP_TITLE=')"
has "$bright" "[97;1m" || fail "16-color index 15 is bright white (97), with bold: $bright"

# ------------------------------------------------------------- callsigns --

callsign() { (export AGENT_STREAM_THEME="$1" AGENT_RUN_COLOR=always ${3:+AGENT_STREAM_EGGS=$3}; _ap_style_init; _ap_callsign "$2"); }
# The same table as cmd/agent-stream-watch/theme_test.go.
[[ "$(callsign space 20261004-050000-ab12cd34)" == ANTARES-4 ]] || fail "space callsign: $(callsign space 20261004-050000-ab12cd34)"
[[ "$(callsign space real1)" == MIRA-3 ]] || fail "space callsign real1"
[[ "$(callsign observatory 20261004-050000-ab12cd34)" == SUBARU-8 ]] || fail "observatory callsign"
[[ "$(callsign observatory real1)" == LICK-1 ]] || fail "observatory callsign real1"
[[ "$(callsign bottling 20261004-050000-ab12cd34)" == BEAN-7 ]] || fail "bottling callsign"
[[ "$(callsign bottling real1)" == POD-2 ]] || fail "bottling callsign real1"
[[ "$(callsign space 20261004-051701-ffffffff)" == ENTERPRISE ]] || fail "1701 with eggs on"
[[ "$(callsign space 20261004-051701-ffffffff 0)" == POLLUX-9 ]] || fail "1701 with eggs off keeps the callsign"

# ------------------------------------------------------------------ eggs --

out="$(pane space | strip)"
has "$out" "three anomalies in a row · don't panic" || fail "three errors in a row"
has "$out" "the Three Laws held" || fail "a denied permission"
has "$out" "42 burns: the answer, apparently" || fail "42 tools at the end"
[[ "$(printf '%s' "$out" | grep -c "don't panic")" == 1 ]] || fail "the streak egg fires once"
for env in AGENT_STREAM_EGGS=0 AGENT_STREAM_LOUDNESS=balanced; do
  out="$(pane space "$env" | strip)"
  ! has "$out" "don't panic" && ! has "$out" "Three Laws" && ! has "$out" "answer, apparently" \
    || fail "no eggs with $env"
done
out="$(pane space AGENT_STREAM_LOUDNESS=balanced | strip)"
has "$out" "ORBIT ACHIEVED" || fail "balanced keeps the theme"
out="$(pane bottling | strip)"
! has "$out" "answer, apparently" || fail "bottling ships with eggs off"
STREAM_SAVE="$STREAM"
STREAM=$'[wait] retry 1/3 in 1ms: x\n[wait] retry 2/3 in 1ms: x\n[wait] retry 3/3 in 1ms: x\n[wait] compacting context'
out="$(pane space | strip)"
has "$out" "a chaotic era: three suns" || fail "the third retry"
has "$out" "the spice must flow" || fail "compaction"
STREAM="$STREAM_SAVE"

# ------------------------------------------------------ project config --

if command -v git >/dev/null 2>&1; then
  P="$TMP/proj"
  mkdir -p "$P/sub/dir" "$P/.agent-stream"
  git -C "$P" init -q
  printf '%s\n' '{"schema":"agent-stream/project/1","theme":"radio","loudness":"loud"}' >"$P/.agent-stream/config.json"
  proj_pane() { (unset AGENT_STREAM_THEME; export AGENT_STREAM_PROJECT_DIR="$P/sub/dir" AGENT_RUN_COLOR=always "$@"; printf '%s\n' "$STREAM" | agent_present_stream) 2>"$TMP/proj.err"; }
  has "$(proj_pane | strip)" "segment Bash make" || fail "the project config picks radio from a subdirectory"
  has "$(proj_pane AGENT_STREAM_THEME=observatory | strip)" "exposure Bash make" || fail "the environment overrides the project"
  printf '%s\n' '{"schema":"agent-stream/theme/1","name":"radio","words":{"tool":"jingle"}}' >"$P/.agent-stream/theme.json"
  has "$(proj_pane | strip)" "jingle Bash make" || fail "a project theme.json named radio overrides radio"
  printf '%s\n' '{"schema":"agent-stream/project/1","theme":"project"}' >"$P/.agent-stream/config.json"
  has "$(proj_pane | strip)" "jingle Bash make" || fail "theme project means .agent-stream/theme.json"
  printf '%s\n' '{"schema":"agent-stream/project/1","theme":"radio","loudness":"quiet"}' >"$P/.agent-stream/config.json"
  [[ "$(proj_pane)" == "$(printf '%s\n' "$STREAM" | AGENT_STREAM_THEME=plain AGENT_RUN_COLOR=always agent_present_stream)" ]] \
    || fail "loudness quiet is the base look"
  printf '%s\n' '{"schema":"agent-stream/project/9"}' >"$P/.agent-stream/config.json"
  proj_pane >/dev/null
  grep -q 'wrong schema' "$TMP/proj.err" || fail "a wrong project schema warns: $(cat "$TMP/proj.err")"
  printf '%s\n' '{"schema":"agent-stream/project/1","theme":"radio","eggs":false}' >"$P/.agent-stream/config.json"
  rm -f "$P/.agent-stream/theme.json"
  ! has "$(proj_pane | strip)" "don't panic" || fail "a project can turn eggs off"
fi

# ------------------------------------------------------- bad theme files --

out="$(pane "$TMP/missing.json")"
[[ "$out" == "$base" ]] || fail "a missing theme file falls back to the base"
grep -q 'not found' "$TMP/pane.err" || fail "a missing explicit theme warns"
printf '%s\n' '{"schema":"agent-stream/theme/1","name":"evil","words":{"tool":"x\u001b[2Jy"},"glyphs":{"unicode":{"active":"\u0007>"}},"eggs":{"bad key":"z","ok":"w"}}' >"$TMP/evil.json"
out="$(pane "$TMP/evil.json")"
! has "$out" $'\033[2J' || fail "control bytes in a theme are stripped"
! has "$out" $'\a' || fail "BEL in a theme is stripped"
has "$(printf '%s' "$out" | strip)" "x[2Jy Bash make" || fail "the theme word survives with its escape byte removed"
printf '%s\n' '{"schema":"wrong"}' >"$TMP/wrong.json"
[[ "$(pane "$TMP/wrong.json")" == "$base" ]] || fail "a wrong schema falls back to the base"
grep -q 'not a valid' "$TMP/pane.err" || fail "a wrong schema warns"

# ----------------------------------------- the record never sees a theme --

cat >"$TMP/worker" <<'W'
#!/usr/bin/env bash
printf '%s\n' '{"type":"system","subtype":"init","model":"m","session_id":"aaaaaaaa"}'
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"a"}}]}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"x","is_error":true}]}}'
W
chmod +x "$TMP/worker"
mkdir -p "$TMP/rec"
(
  set +e
  export AGENT_STREAM_THEME=space AGENT_RUN_COLOR=always
  run="$TMP/rec"; lib="$ROOT/lib"
  # shellcheck source=../lib/run-capture.sh
  . "$ROOT/lib/run-capture.sh"
  run_capture_exec claude-json -- "$TMP/worker" >"$TMP/rec.pane" 2>&1
)
has "$(strip <"$TMP/rec.pane")" "anomaly Read" || fail "the pane is themed"
! grep -q 'anomaly\|burn\|ignition' "$TMP/rec/display.txt" || fail "display.txt never carries theme words"
! grep -q $'\033' "$TMP/rec/display.txt" || fail "display.txt stays plain"
[[ "$(jq -r '.theme.name + " " + .theme.loudness' "$TMP/rec/state.json")" == "space loud" ]] \
  || fail "state.json records the theme the run asked for: $(jq -c .theme "$TMP/rec/state.json")"

echo "agent-theme test: all assertions passed"
