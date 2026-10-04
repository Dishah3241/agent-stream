#!/usr/bin/env bash
# agent-present.sh: terminal presentation layer for agent-run. Sourced by the
# CLI integration; every function reads one record on stdin and writes
# humanity-oriented output to stdout. Nothing here parses events, captures
# logs, stores goals, or changes state; saved dumps stay plain because color
# exists only in this terminal layer.
#
# Palette (quiet, never color alone — every state also carries a word and a
# mark): cyan headings and active runs, dim metadata, green success, amber
# needs-attention, red errors. Color is decided by AGENT_RUN_COLOR
# (always|never|auto, default auto: color only on a terminal). NO_COLOR wins
# over even an explicit color request; TERM=dumb and non-TTY output stay
# plain. Marks and card borders fall back to ASCII for TERM=dumb and
# non-UTF-8 locales.
#
# Every string that originates from records, harnesses, or workers is stripped
# of terminal controls (OSC, CSI, other escapes, carriage returns, and other
# C0/DEL bytes) before it is printed; unicode, tabs, and newlines survive.
# Paths are shown whole so they stay usable; only a leading $HOME is
# shortened to ~. Open runs point at `agent-run --follow <id>`, not `tail -f`.
#
# Header, record, and goal each accept exactly one JSON object and are
# framed by a dim horizontal rule (width rule: _ap_hr). Multiple documents
# are rejected. Non-scalar field values are not dumped.
#
# agent_present_stream is streaming: assistant text without a newline is
# written as it arrives. Label lines ([tool], [done], [error], [warn], [note], [think]) are
# restyled only once a complete line is in hand: tool activity reads as
# bordered cards ("┌─ · read path" … "└─ ✓ read"), notes, warnings, and
# errors outside any card carry a side border ("│ …"), thinking opens as a
# divider ("── · think"), and a blank line separates each card from whatever
# was printed before it. Ordinary bracket-leading text is not buffered.
# Escape sequences are completed before sanitizing so a split CSI cannot
# leak leftover "[31m" text. No per-byte subprocess.
#
# Bash 3.2 compatible: no mapfile, associative arrays, or ${var,,}.
# External commands: jq, plus sed only for strings that carry control bytes.

_AP_ESC=$'\033'
_AP_BEL=$'\007'
# CSI final bytes 0x40-0x7E. Do not use a glob range: UTF-8 locales
# make [@-~] miss ASCII letters.
_AP_CSI_FINALS='@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~'
_AP_AS_SCALAR='if type == "string" or type == "number" or type == "boolean" then tostring else "" end'

# Design files (themes/): words, glyphs, colors, backgrounds, gauges, and
# eggs over the base look. See lib/agent-theme.sh.
# shellcheck source=agent-theme.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-theme.sh"

# _ap_style_init: set palette variables and marks from the environment. Runs
# at the top of each public function, so callers may flip AGENT_RUN_COLOR
# between calls.
_ap_style_init() {
  _AP_RESET='' _AP_HEAD='' _AP_DIM='' _AP_OK='' _AP_WARN='' _AP_ERR=''
  _AP_COLOR=0
  case "${AGENT_RUN_COLOR:-auto}" in
    always) _AP_COLOR=1 ;;
    never) : ;;
    auto)
      if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" && -t 1 ]]; then
        _AP_COLOR=1
      fi
      ;;
  esac
  if [[ -n "${NO_COLOR:-}" ]]; then
    _AP_COLOR=0
  fi
  if [[ "${TERM:-dumb}" == "dumb" ]]; then
    _AP_COLOR=0
  fi
  if [[ "$_AP_COLOR" == 1 ]]; then
    _AP_RESET=$'\033[0m'
    _AP_HEAD=$'\033[36m'
    _AP_DIM=$'\033[2m'
    _AP_OK=$'\033[32m'
    _AP_WARN=$'\033[33m'
    _AP_ERR=$'\033[31m'
  fi
  # Marks and separators: unicode where the terminal plausibly renders it,
  # ASCII otherwise. Every non-ASCII glyph printed anywhere comes from here.
  # Waiting keeps "~" in both sets: it reads as "pending" everywhere and the
  # word "waiting" always accompanies it.
  _AP_M_HEAD='>' _AP_M_STEP='-' _AP_M_DONE='+' _AP_M_ERR='x' _AP_M_WARN='!'
  _AP_M_UNK='?' _AP_M_IDLE='.' _AP_M_WAIT='~' _AP_M_DROP='-' _AP_SEP='-' _AP_DASH='-'
  _AP_TL='+' _AP_BL='+' _AP_H='-' _AP_V='|' _AP_H2='--'
  _AP_WIDTH=80
  local ctype="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ "${TERM:-}" != "dumb" && "$ctype" == *[Uu][Tt][Ff]-8* ]]; then
    _AP_M_HEAD='▸' _AP_M_STEP='·' _AP_M_DONE='✓' _AP_M_ERR='✗' _AP_M_WARN='!'
    _AP_M_UNK='?' _AP_M_IDLE='·' _AP_M_WAIT='~' _AP_M_DROP='–' _AP_SEP='·' _AP_DASH='—'
    _AP_TL='┌' _AP_BL='└' _AP_H='─' _AP_V='│' _AP_H2='──'
  fi
  _AP_ELL='...'
  if [[ "${TERM:-}" != "dumb" && "$ctype" == *[Uu][Tt][Ff]-8* ]]; then
    _AP_ELL='…'
  fi
  local _w="${COLUMNS:-80}"
  case "$_w" in ''|*[!0-9]*) _w=80 ;; esac
  if (( _w < 40 )); then _w=40; fi
  if (( _w > 120 )); then _w=120; fi
  _AP_WIDTH="$_w"
  _ap_repeat _AP_RULE "$_AP_H" "$_AP_WIDTH"
  _ap_theme_apply
}

# _ap_repeat VAR CHAR COUNT: store CHAR repeated COUNT times in VAR (box
# rules without seq or a subshell).
_ap_repeat() {
  local ch="$2" n="$3" out="" i=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  while (( i < n )); do out="${out}${ch}"; i=$((i + 1)); done
  printf -v "$1" '%s' "$out"
}

# _ap_hr: one dim horizontal rule. Its width is COLUMNS when the caller
# exports it (80 otherwise), clamped to 40..120. Frames headers, records,
# and goals so sections read as cards. Body text is never truncated or
# rewrapped to fit; only the rule itself stretches.
_ap_hr() {
  printf '%s%s%s\n' "$_AP_DIM" "$_AP_RULE" "$_AP_RESET"
}

# _ap_air: one blank line between cards, skipped only before the first
# visible output of the stream.
_ap_air() {
  if [[ "${_AP_STREAM_STARTED:-0}" == 1 ]]; then
    printf '\n'
  fi
}

# _ap_box_open TEXT: air, then a bordered opener like "┌─ · read path" that
# leaves a card open. Borders reuse the dim style so the documented palette
# never grows; only the glyphs are new.
_ap_box_open() {
  _ap_air
  printf '%s%s%s%s %s\n' "$_AP_DIM" "$_AP_TL" "$_AP_H" "$_AP_RESET" "$1"
  _AP_OPEN_CARDS=$(( ${_AP_OPEN_CARDS:-0} + 1 ))
  _AP_STREAM_STARTED=1
}

# _ap_box_close LINE: bordered closer like "└─ ✓ read" for the open card. A
# closer with no open card (run-level errors, compaction) keeps its mark but
# takes the side border, so "└─" only ever answers a "┌─".
_ap_box_close() {
  if (( ${_AP_OPEN_CARDS:-0} > 0 )); then
    _AP_OPEN_CARDS=$(( _AP_OPEN_CARDS - 1 ))
    printf '%s%s%s%s %s\n' "$_AP_DIM" "$_AP_BL" "$_AP_H" "$_AP_RESET" "$1"
    _AP_STREAM_STARTED=1
  else
    _ap_box_side "$1"
  fi
}

# _ap_divider TEXT: air, then a dim divider like "── · think".
_ap_divider() {
  _ap_air
  printf '%s%s%s %s\n' "$_AP_DIM" "$_AP_H2" "$_AP_RESET" "$1"
  _AP_STREAM_STARTED=1
}

# _ap_box_side LINE: side-bordered continuation like "│ note text".
_ap_box_side() {
  printf '%s%s%s %s\n' "$_AP_DIM" "$_AP_V" "$_AP_RESET" "$1"
  _AP_STREAM_STARTED=1
}

# _ap_has_unsafe STRING: true when STRING carries a control we must strip
# (ESC, CR, C0 other than TAB/LF, DEL).
_ap_has_unsafe() {
  case "$1" in
    *[$'\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177\r']*)
      return 0 ;;
  esac
  return 1
}

# _ap_sanitize STRING: strip terminal controls (OSC, CSI, DCS leftovers,
# other escapes, CR, remaining C0/DEL), keep unicode, tabs, and newlines.
_ap_sanitize() {
  local s="$1"
  if ! _ap_has_unsafe "$s"; then
    printf '%s' "$s"
    return 0
  fi
  s="$(printf '%s' "$s" | LC_ALL=C sed \
    -e "s/$_AP_ESC\\][^$_AP_BEL]*$_AP_BEL//g" \
    -e "s/$_AP_ESC\\][^$_AP_ESC]*$_AP_ESC\\\\//g" \
    -e "s/$_AP_ESC\\[[ -?]*[@-~]//g" \
    -e "s/$_AP_ESC.//g" \
    -e "s/$_AP_ESC//g" \
    -e $'s/\r//g' \
    -e $'s/[\001-\010\013\014\016-\037\177]//g')"
  printf '%s' "$s"
}

# _ap_path PATH: shorten a leading $HOME to ~; everything else stays whole.
_ap_path() {
  local p="$1"
  if [[ -n "$HOME" && ( "$p" == "$HOME" || "$p" == "$HOME"/* ) ]]; then
    p="~${p#"$HOME"}"
  fi
  printf '%s' "$p"
}

# _ap_field LABEL TEXT: one "  label    content" metadata line.
_ap_field() {
  printf '  %s%-7s%s %s\n' "$_AP_DIM" "$1" "$_AP_RESET" "$2"
}

# _ap_count N WORD: "1 tool", "2 tools".
_ap_count() {
  local n="$1"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [[ "$n" == 1 ]]; then printf '%s %s' "$n" "$2"
  elif [[ "$2" == *[!aeiou]y ]]; then printf '%s %sies' "$n" "${2%y}"
  else printf '%s %ss' "$n" "$2"; fi
}

# _ap_duration SECONDS: 42s, 3m12s, 1h02m. Non-numbers read as 0s.
_ap_duration() {
  local s="$1"
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if (( s < 60 )); then printf '%ss' "$s"
  elif (( s < 3600 )); then printf '%sm%02ds' "$((s / 60))" "$((s % 60))"
  else printf '%sh%02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

# _ap_shorten TEXT WIDTH: one line, cut to WIDTH with an ellipsis mark.
# Tabs and newlines fold to spaces. Used for the task in headers and cards;
# the full text lives in the record.
_ap_shorten() {
  local t="$1" w="$2"
  t="${t//$'\n'/ }"
  t="${t//$'\t'/ }"
  case "$w" in ''|*[!0-9]*) w=60 ;; esac
  if (( w < 8 )); then w=8; fi
  if (( ${#t} > w )); then
    printf '%s%s' "${t:0:$((w - 1))}" "$_AP_ELL"
  else
    printf '%s' "$t"
  fi
}

# _ap_json PAYLOAD EXPRESSION: evaluate a jq expression that yields raw
# text. jq -r decodes \uXXXX escapes, so sanitization downstream sees the
# real bytes an attacker sent.
_ap_json() {
  printf '%s' "$1" | jq -r "$2" 2>/dev/null
}

_ap_scalar() {
  _ap_json "$1" "$2 | ${_AP_AS_SCALAR}"
}

# _ap_read_one_object USAGE: slurp stdin into _AP_PAYLOAD. Exactly one JSON
# object, or print USAGE on stderr and return 2.
_ap_read_one_object() {
  local usage="$1"
  _AP_PAYLOAD="$(cat)" || return 2
  if ! printf '%s' "$_AP_PAYLOAD" | jq -ne '
    [inputs] as $docs
    | ($docs | length) == 1 and ($docs[0] | type) == "object"
  ' >/dev/null 2>&1; then
    echo "agent-present: $usage" >&2
    return 2
  fi
  return 0
}

# _ap_tsv LINE INDEX: field INDEX (0-based) of a jq @tsv line. Splitting is
# manual because IFS would collapse the empty fields @tsv writes. @tsv escapes
# tabs and newlines inside values, so every tab here is a true separator.
_ap_tsv() {
  local s="$1" i="$2"
  while (( i > 0 )); do
    s="${s#*$'\t'}"
    i=$((i - 1))
  done
  printf '%s' "${s%%$'\t'*}"
}

# _ap_todo_row REST: "I/N STATUS text" as one plan row. Consecutive rows
# share one "── · plan" divider; the mark and the position carry the state
# without color: ✓ done, ▸ active, · pending, – dropped (+ > . - in ASCII).
_ap_todo_row() {
  local rest="$1" pos status text mark color body
  pos="${rest%% *}"; rest="${rest#"$pos"}"; rest="${rest# }"
  status="${rest%% *}"; text="${rest#"$status"}"; text="${text# }"
  case "$status" in
    done)    mark="$_AP_G_LIT" color="$_AP_OK" ;;
    active)  mark="$_AP_G_ACTIVE" color="$_AP_HEAD" ;;
    dropped) mark="$_AP_G_DROP" color="$_AP_DIM" ;;
    pending) mark="$_AP_G_PENDING" color="$_AP_DIM" ;;
    *)       mark="$_AP_M_UNK" color="$_AP_WARN"; text="$status $text"; status="" ;;
  esac
  _ap_plan_note "$pos" "$status"
  if [[ "${_AP_PREV_TODO:-0}" != 1 ]]; then
    printf -v body '%s%s %s%s' "$_AP_DIM" "$_AP_M_STEP" "$_AP_W_PLAN" "$_AP_RESET"
    _ap_divider "$body"
  fi
  case "$status" in
    active) printf -v body '%s%s%s %s%s%s %s' "$color" "$mark" "$_AP_RESET" "$_AP_DIM" "$pos" "$_AP_RESET" "$text" ;;
    done)   printf -v body '%s%s%s %s%s %s%s' "$color" "$mark" "$_AP_RESET" "$_AP_DIM" "$pos" "$text" "$_AP_RESET" ;;
    *)      printf -v body '%s%s %s %s%s' "$color" "$mark" "$pos" "$text" "$_AP_RESET" ;;
  esac
  _ap_box_side "$body"
  _AP_PREV_TODO=1
}

# _ap_plan_note POS STATUS: remember a plan item ("I/N") so the theme's
# gauge can draw the whole plan when the block of plan rows ends.
_ap_plan_note() {
  local i="${1%%/*}" n="${1#*/}" k letter
  case "$i$n" in ''|*[!0-9]*) return 0 ;; esac
  (( i >= 1 && i <= n && n <= 500 )) || return 0
  if [[ "$n" != "${_AP_PLAN_N:-0}" ]]; then
    for (( k = ${_AP_PLAN_N:-0}; k < n; k++ )); do _AP_PLAN[k]=p; done
    _AP_PLAN_N=$n
  fi
  case "$2" in done) letter=d ;; active) letter=a ;; dropped) letter=x ;; *) letter=p ;; esac
  _AP_PLAN[i-1]=$letter
  return 0
}

# _ap_plan_close: a block of plan rows has ended; a theme with a gauge
# draws the plan's progress under it, like "│ ✦━━➤┈┈·  altitude 1/3".
_ap_plan_close() {
  local st='' k d=0 g
  if [[ "${_AP_PREV_TODO:-0}" == 1 && -n "${_AP_GAUGE:-}" && "${_AP_PLAN_N:-0}" -gt 0 ]]; then
    for (( k = 0; k < _AP_PLAN_N; k++ )); do
      st="$st${_AP_PLAN[k]:-p}"
      case "${_AP_PLAN[k]:-p}" in d|x) d=$((d + 1)) ;; esac
    done
    g="$(_ap_gauge "$st" 30)"
    _ap_box_side "$g  $_AP_DIM$_AP_W_ALTITUDE $d/$_AP_PLAN_N$_AP_RESET"
  fi
  _AP_PREV_TODO=0
}

# _ap_egg_line ID: an easter egg as one extra dim side line, when on.
_ap_egg_line() {
  local e
  e="$(_ap_egg "$1")"
  [[ -z "$e" ]] || _ap_box_side "$_AP_EGGC$e$_AP_RESET"
  return 0
}

_ap_emit_stream_line() {
  local line rest name body kind word
  line="$(_ap_sanitize "$1")"
  case "$line" in
    "[todo]"|"[todo] "*) ;;
    *) _ap_plan_close ;;
  esac
  case "$line" in
    "[todo]"|"[todo] "*)
      rest="${line#\[todo\]}"; rest="${rest# }"
      _ap_todo_row "$rest"
      ;;
    "[wait]"|"[wait] "*)
      rest="${line#\[wait\]}"; rest="${rest# }"
      kind="${rest%% *}"; kind="${kind%:}"
      rest="${rest#"${rest%% *}"}"; rest="${rest# }"
      if [[ -n "$kind" ]]; then
        printf -v body '%s%s %s%s %s(%s)%s %s' "$_AP_WARN" "$_AP_M_WAIT" "$_AP_W_WAIT" "$_AP_RESET" "$_AP_DIM" "$kind" "$_AP_RESET" "$rest"
      else
        printf -v body '%s%s %s%s' "$_AP_WARN" "$_AP_M_WAIT" "$_AP_W_WAIT" "$_AP_RESET"
      fi
      _ap_box_side "$body"
      case "$kind" in
        retry)
          _AP_RETRIES=$(( ${_AP_RETRIES:-0} + 1 ))
          if (( _AP_RETRIES == 3 )); then _ap_egg_line chaotic_era; fi ;;
        compacting) _ap_egg_line spice ;;
      esac
      ;;
    "[step]"|"[step] "*)
      rest="${line#\[step\]}"; rest="${rest# }"
      printf -v body '%s%s%s %s' "$_AP_DIM" "$_AP_W_STEP" "$_AP_RESET" "$rest"
      _ap_box_side "$body"
      ;;
    "[run] result "*)
      rest="${line#\[run\] result }"
      case "$rest" in
        success*|end_turn*|end*|stop*)
          printf -v body '%s%s%s %s%sresult %s%s' "$_AP_OK" "$_AP_M_DONE" "$_AP_RESET" "$_AP_DIM" "${_AP_W_RESULT_OK:+$_AP_W_RESULT_OK }" "$rest" "$_AP_RESET" ;;
        *)
          printf -v body '%s%s%s result %s' "$_AP_WARN" "$_AP_M_WARN" "$_AP_RESET" "$rest" ;;
      esac
      _ap_box_side "$body"
      case "$rest" in *" denied)"*) _ap_egg_line three_laws ;; esac
      ;;
    "[run]"|"[run] "*)
      rest="${line#\[run\]}"; rest="${rest# }"
      printf -v body '%s%s%s %s%s' "${_AP_G_LAUNCH:+$_AP_HEAD$_AP_G_LAUNCH$_AP_RESET }" "$_AP_DIM" "$_AP_W_RUN" "$rest" "$_AP_RESET"
      _ap_box_side "$body"
      ;;
    "[end]"|"[end] "*)
      rest="${line#\[end\]}"; rest="${rest# }"
      kind="${rest%% *}"
      case "$kind" in
        success)          printf -v body '%s%s%s %s' "$_AP_OK" "$_AP_M_DONE" "$_AP_RESET" "$rest" ;;
        failed|error)     printf -v body '%s%s %s%s' "$_AP_ERR" "$_AP_M_ERR" "$rest" "$_AP_RESET" ;;
        cancelled)        printf -v body '%s%s %s%s' "$_AP_WARN" "$_AP_M_WARN" "$rest" "$_AP_RESET" ;;
        *)                printf -v body '%s%s %s%s' "$_AP_DIM" "$_AP_M_IDLE" "$rest" "$_AP_RESET" ;;
      esac
      _ap_divider "$body"
      ;;
    "[tool]"|"[tool] "*)
      rest="${line#\[tool\]}"; rest="${rest# }"
      if [[ -n "$rest" ]]; then
        name="${rest%% *}"
        printf -v body '%s %s%s%s%s%s' "$_AP_M_STEP" "$_AP_DIM" "${_AP_W_TOOL:+$_AP_W_TOOL }" "$name" "$_AP_RESET" "${rest#"$name"}"
      else
        body="$_AP_M_STEP"
      fi
      _ap_box_open "$body"
      ;;
    "[done]"|"[done] "*)
      rest="${line#\[done\]}"; rest="${rest# }"
      _AP_ERR_STREAK=0
      printf -v body '%s%s%s %s%s%s%s' "$_AP_OK" "$_AP_M_DONE" "$_AP_RESET" "$_AP_DIM" "$rest" "${_AP_W_DONE:+ $_AP_W_DONE}" "$_AP_RESET"
      _ap_box_close "$body"
      ;;
    "[error]"|"[error] "*)
      rest="${line#\[error\]}"; rest="${rest# }"
      printf -v body '%s%s%s %s%s%s%s' "$_AP_ERR" "$_AP_M_ERR" "$_AP_RESET" "$_AP_ERR" "${_AP_W_ERROR:+$_AP_W_ERROR }" "$rest" "$_AP_RESET"
      _ap_box_close "$body"
      _AP_ERR_STREAK=$(( ${_AP_ERR_STREAK:-0} + 1 ))
      if (( _AP_ERR_STREAK == 3 )); then _ap_egg_line error_streak; fi
      ;;
    "[warn]"|"[warn] "*)
      rest="${line#\[warn\]}"; rest="${rest# }"
      printf -v body '%s%s%s %s%s%s%s' "$_AP_WARN" "$_AP_M_WARN" "$_AP_RESET" "$_AP_WARN" "${_AP_W_WARN:+$_AP_W_WARN }" "$rest" "$_AP_RESET"
      _ap_box_side "$body"
      ;;
    "[note]"|"[note] "*)
      rest="${line#\[note\]}"; rest="${rest# }"
      printf -v body '%s%s%s%s' "$_AP_DIM" "${_AP_W_NOTE:+$_AP_W_NOTE }" "$rest" "$_AP_RESET"
      _ap_box_side "$body"
      ;;
    "[think]"|"[think] "*)
      rest="${line#\[think\]}"; rest="${rest# }"
      if [[ -n "$rest" ]]; then
        printf -v body '%s%s %s%s %s' "$_AP_THINK" "$_AP_M_IDLE" "$_AP_W_THINK" "$_AP_RESET" "$rest"
      else
        printf -v body '%s%s %s%s' "$_AP_THINK" "$_AP_M_IDLE" "$_AP_W_THINK" "$_AP_RESET"
      fi
      _ap_divider "$body"
      ;;
    *)
      printf '%s\n' "$line"
      _AP_STREAM_STARTED=1
      ;;
  esac
}

# Hold only recognized label prefixes, not every "[" opener.
_ap_label_hold() {
  case "$1" in
    '['|'[t'|'[to'|'[too'|'[tool'|'[tod'|'[todo'|'[th'|'[thi'|'[thin'|'[think'|'[d'|'[do'|'[don'|'[done'|'[e'|'[er'|'[err'|'[erro'|'[error'|'[en'|'[end'|'[w'|'[wa'|'[war'|'[warn'|'[wai'|'[wait'|'[n'|'[no'|'[not'|'[note'|'[r'|'[ru'|'[run'|'[s'|'[st'|'[ste'|'[step')
      return 0 ;;
    '[tool]'*|'[done]'*|'[error]'*|'[warn]'*|'[note]'*|'[think]'*|'[wait]'*|'[todo]'*|'[step]'*|'[run]'*|'[end]'*)
      return 0 ;;
  esac
  return 1
}

# _ap_is_label LINE: a complete line that the stream restyles.
_ap_is_label() {
  case "$1" in
    '[tool]'*|'[done]'*|'[error]'*|'[warn]'*|'[note]'*|'[think]'*|'[wait]'*|'[todo]'*|'[step]'*|'[run]'*|'[end]'*)
      return 0 ;;
  esac
  return 1
}

_ap_emit_plain() {
  if [[ -z "$1" ]]; then
    return 0
  fi
  _ap_plan_close
  if _ap_has_unsafe "$1"; then
    _ap_sanitize "$1"
  else
    printf '%s' "$1"
  fi
  _AP_STREAM_STARTED=1
}

_ap_stream_flush_plain() {
  if [[ -n "${_AP_PLAIN:-}" ]]; then
    _ap_emit_plain "$_AP_PLAIN"
    _AP_PLAIN=""
  fi
}

# _ap_state_fields: one @tsv line from $run/state.json, or nothing. Fields:
# 0 elapsed 1 project 2 branch 3 todo done 4 todo total 5 active todo
# 6 activity kind 7 activity text 8 waiting text 9 tools 10 errors
# 11 status 12 step. One jq call; every field is sanitized by the caller.
_ap_state_fields() {
  local f="${run:-}/state.json"
  [[ -n "${run:-}" && -r "$f" && ! -L "$f" ]] || return 1
  jq -r '
    def s: if type == "string" or type == "number" then tostring else "" end;
    [ (if .status == "ended" then (.elapsed_s // 0)
       else ((now - ((.started_at | fromdate?) // now)) | floor) end),
      (.project.name | s), (.project.branch | s),
      (.todo_counts.done // 0), (.todo_counts.total // 0),
      ([.todos[]? | select(.status == "active") | .text] | first // ""),
      (.activity.kind | s), (.activity.text | s),
      (if .waiting == null then "" else ((.waiting.kind | s) + " " + (.waiting.text | s)) end),
      (.counts.tools // 0), (.counts.errors // 0),
      (.status | s), (.step | s) ] | @tsv' "$f" 2>/dev/null
}

# _ap_status_card: one dim line that answers "where is this run" from the
# state file: elapsed, project and branch, plan progress, what is happening
# now or what it is waiting for, tool and error counts. Terminal only; it
# is never part of display.txt.
_ap_status_card() {
  local row el proj branch ndone total active akind atext waiting tools errors st step
  local now_word="" card
  row="$(_ap_state_fields)" || return 0
  [[ -n "$row" ]] || return 0
  el="$(_ap_tsv "$row" 0)"; proj="$(_ap_sanitize "$(_ap_tsv "$row" 1)")"
  branch="$(_ap_sanitize "$(_ap_tsv "$row" 2)")"
  ndone="$(_ap_tsv "$row" 3)"; total="$(_ap_tsv "$row" 4)"
  active="$(_ap_sanitize "$(_ap_tsv "$row" 5)")"
  akind="$(_ap_tsv "$row" 6)"; atext="$(_ap_sanitize "$(_ap_tsv "$row" 7)")"
  waiting="$(_ap_sanitize "$(_ap_tsv "$row" 8)")"
  tools="$(_ap_tsv "$row" 9)"; errors="$(_ap_tsv "$row" 10)"
  st="$(_ap_tsv "$row" 11)"; step="$(_ap_sanitize "$(_ap_tsv "$row" 12)")"
  card="$(_ap_duration "$el")"
  if [[ -n "$proj" ]]; then card="$card $_AP_SEP $proj${branch:+ $branch}"; fi
  if [[ "$total" != 0 && -n "$total" ]]; then
    card="$card $_AP_SEP plan $ndone/$total"
    if [[ -n "$active" ]]; then card="$card: $(_ap_shorten "$active" 40)"; fi
  fi
  if [[ -n "$waiting" && "$st" == "waiting" ]]; then
    now_word="${_AP_WARN}waiting${_AP_RESET} $(_ap_shorten "$waiting" 50)"
  elif [[ -n "$step" ]]; then
    now_word="now $(_ap_shorten "$step" 50)"
  elif [[ "$akind" == "tool" && -n "$atext" ]]; then
    now_word="now $(_ap_shorten "$atext" 50)"
  elif [[ "$akind" == "think" ]]; then
    now_word="thinking"
  elif [[ -n "$atext" ]]; then
    now_word="last $(_ap_shorten "$atext" 50)"
  fi
  if [[ -n "$now_word" ]]; then card="$card $_AP_SEP $now_word"; fi
  card="$card $_AP_SEP $(_ap_count "$tools" tool)"
  if [[ "$errors" != 0 ]]; then card="$card, ${_AP_ERR}$(_ap_count "$errors" error)${_AP_RESET}"; fi
  printf '%s%s%s %s%s%s\n' "$_AP_DIM" "$_AP_H2" "$_AP_RESET" "$_AP_DIM" "$card" "$_AP_RESET"
}

# One plain identity line on the first rendered line and every 40 after,
# so a 120-line pane read still shows the run and the display path, and a
# status card from state.json on the same cadence when a record is set.
_ap_stream_note() {
  [[ -n "${AGENT_RUN_RUN:-}${run:-}" ]] || return 0
  _AP_NOTE_LINES=$(( ${_AP_NOTE_LINES:-0} + 1 ))
  if (( _AP_NOTE_LINES != 1 && _AP_NOTE_LINES % 40 != 0 )); then
    return 0
  fi
  local dest="display.txt"
  if [[ -n "${run:-}" ]]; then
    dest="$run/display.txt"
  fi
  if [[ -n "${AGENT_RUN_RUN:-}" ]]; then
    printf 'agent-run %s streaming %s\n' "$AGENT_RUN_RUN" "$dest"
  fi
  if (( _AP_NOTE_LINES != 1 )); then
    _ap_plan_close
    _ap_status_card
  fi
}

# ------------------------------------------------------------ pinned mode --
# AGENT_RUN_STATUS=pinned keeps a two-line footer at the bottom of the
# terminal while the stream scrolls above it in a DECSTBM region. Terminal
# only: it needs a tty, a TERM that is not dumb, and tput; it never writes
# to any file. The footer is redrawn at most once a second from state.json.
# Known cost: lines that scroll inside a reduced region do not reach the
# scrollback of several terminals, which is why this is opt-in.
_ap_pinned_init() {
  _AP_PIN=0
  [[ "${AGENT_RUN_STATUS:-}" == pinned ]] || return 0
  [[ -t 1 && "${TERM:-dumb}" != dumb ]] || return 0
  command -v tput >/dev/null 2>&1 || return 0
  _AP_PIN_ROWS="$(tput lines 2>/dev/null)" || return 0
  _AP_PIN_COLS="$(tput cols 2>/dev/null)" || return 0
  case "$_AP_PIN_ROWS$_AP_PIN_COLS" in *[!0-9]*|'') return 0 ;; esac
  (( _AP_PIN_ROWS >= 6 )) || return 0
  _AP_PIN=1
  _AP_PIN_TOP=$(( _AP_PIN_ROWS - 2 ))
  _AP_PIN_LAST=-1
  printf '\033[1;%dr\033[%d;1H' "$_AP_PIN_TOP" "$_AP_PIN_TOP"
  trap '_ap_pinned_exit' EXIT
  trap '_ap_pinned_exit; exit 130' INT TERM
  trap '_ap_pinned_resize' WINCH
}

_ap_pinned_resize() {
  local rows
  rows="$(tput lines 2>/dev/null)" || return 0
  case "$rows" in ''|*[!0-9]*) return 0 ;; esac
  (( rows >= 6 )) || return 0
  _AP_PIN_ROWS="$rows"
  _AP_PIN_COLS="$(tput cols 2>/dev/null || echo 80)"
  _AP_PIN_TOP=$(( rows - 2 ))
  printf '\033[1;%dr' "$_AP_PIN_TOP"
  _AP_PIN_LAST=-1
}

_ap_pinned_exit() {
  [[ "${_AP_PIN:-0}" == 1 ]] || return 0
  printf '\033[r\033[%d;1H\033[J' "$_AP_PIN_TOP"
  _AP_PIN=0
}

# _ap_pinned_draw: save cursor, write both footer rows cut to the width,
# restore cursor. Plain text fields only; color stays inside the palette.
_ap_pinned_draw() {
  [[ "${_AP_PIN:-0}" == 1 ]] || return 0
  if [[ "$SECONDS" == "$_AP_PIN_LAST" ]]; then return 0; fi
  _AP_PIN_LAST="$SECONDS"
  local row el proj branch ndone total active akind atext waiting tools errors st step
  local l1 l2 w=$(( _AP_PIN_COLS - 1 ))
  row="$(_ap_state_fields)" || row=""
  if [[ -z "$row" ]]; then
    l1="$(_ap_duration "$SECONDS") $_AP_SEP no state yet"
    l2=""
  else
    el="$(_ap_tsv "$row" 0)"; proj="$(_ap_sanitize "$(_ap_tsv "$row" 1)")"
    branch="$(_ap_sanitize "$(_ap_tsv "$row" 2)")"
    ndone="$(_ap_tsv "$row" 3)"; total="$(_ap_tsv "$row" 4)"
    active="$(_ap_sanitize "$(_ap_tsv "$row" 5)")"
    akind="$(_ap_tsv "$row" 6)"; atext="$(_ap_sanitize "$(_ap_tsv "$row" 7)")"
    waiting="$(_ap_sanitize "$(_ap_tsv "$row" 8)")"
    tools="$(_ap_tsv "$row" 9)"; errors="$(_ap_tsv "$row" 10)"
    st="$(_ap_tsv "$row" 11)"; step="$(_ap_sanitize "$(_ap_tsv "$row" 12)")"
    l1="${proj:-run}${branch:+ $branch} $_AP_SEP $(_ap_duration "$el")"
    if [[ "$total" != 0 && -n "$total" ]]; then l1="$l1 $_AP_SEP plan $ndone/$total"; fi
    l1="$l1 $_AP_SEP $(_ap_count "$tools" tool)"
    if [[ "$errors" != 0 && -n "$errors" ]]; then l1="$l1, $(_ap_count "$errors" error)"; fi
    if [[ "$st" == ended ]]; then l2="ended"
    elif [[ "$st" == waiting && -n "$waiting" ]]; then l2="waiting $waiting"
    elif [[ -n "$active" ]]; then l2="step $active${step:+ $_AP_SEP $step}"
    elif [[ -n "$step" ]]; then l2="now $step"
    elif [[ "$akind" == tool ]]; then l2="now $atext"
    else l2="${akind:-idle} ${atext}"
    fi
  fi
  l1="$(_ap_shorten "$l1" "$w")"
  l2="$(_ap_shorten "$l2" "$w")"
  printf '\0337\033[%d;1H\033[K%s%s%s\033[%d;1H\033[K%s%s%s\0338' \
    "$(( _AP_PIN_TOP + 1 ))" "$_AP_DIM" "$l1" "$_AP_RESET" \
    "$(( _AP_PIN_TOP + 2 ))" "$_AP_DIM" "$l2" "$_AP_RESET"
}

_ap_stream_putc() {
  local c="$1" last
  _AP_STREAM_HAD_OUTPUT=1
  if [[ "$c" == $'\n' ]]; then _AP_STREAM_TRAILING_NEWLINE=1; else _AP_STREAM_TRAILING_NEWLINE=0; fi
  if [[ -n "${_AP_ESC_BUF:-}" ]]; then
    _AP_ESC_BUF="${_AP_ESC_BUF}${c}"
    if [[ "$_AP_ESC_BUF" == $'\033['* ]]; then
      if [[ ${#_AP_ESC_BUF} -ge 3 ]]; then
        last="${_AP_ESC_BUF#${_AP_ESC_BUF%?}}"
        case "$_AP_CSI_FINALS" in
          *"$last"*) _AP_ESC_BUF="" ;;
        esac
      fi
      return 0
    fi
    if [[ "$_AP_ESC_BUF" == $'\033]'* ]]; then
      case "$_AP_ESC_BUF" in
        *$'\007'|*$'\033\\') _AP_ESC_BUF="" ;;
      esac
      return 0
    fi
    if [[ ${#_AP_ESC_BUF} -ge 2 ]]; then
      _AP_ESC_BUF=""
    fi
    return 0
  fi

  if [[ "$c" == $'\033' ]]; then
    _ap_stream_flush_plain
    _AP_ESC_BUF=$'\033'
    return 0
  fi

  if [[ -n "${_AP_LINE:-}" || "$c" == '[' ]]; then
    _ap_stream_flush_plain
    if [[ "$c" == $'\n' ]]; then
      _ap_emit_stream_line "$_AP_LINE"
      _AP_LINE=""
      _ap_stream_note
      _ap_pinned_draw
      return 0
    fi
    _AP_LINE="${_AP_LINE}${c}"
    if _ap_label_hold "$_AP_LINE"; then
      return 0
    fi
    _ap_emit_plain "$_AP_LINE"
    _AP_LINE=""
    return 0
  fi

  if [[ "$c" == $'\n' ]]; then
    _ap_stream_flush_plain
    printf '\n'
    _ap_plan_close
    _ap_stream_note
    _ap_pinned_draw
    return 0
  fi
  _AP_PLAIN="${_AP_PLAIN}${c}"
}

# agent_present_header: read one JSON object {id,agent,label,cwd,dir,
# model_requested?,model_source?,project?,branch?,task?} and print a compact
# run header: who is working where, on what. The title is the project and
# branch when known, else the label, else the run id. The task is shown
# shortened to the rule width; the record keeps it in full. The model line
# always says "requested"; a null request is shown as the harness default.
# This layer never claims to know the model that actually ran.
agent_present_header() {
  _ap_style_init
  local id agent label cwd dir model_requested model_source project branch task
  local title model_src
  _ap_read_one_object "header input is not a single JSON object" || return 2
  id="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.id')")"
  agent="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.agent')")"
  label="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.label')")"
  cwd="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.cwd')")"
  dir="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.dir')")"
  model_requested="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.model_requested')")"
  model_source="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.model_source')")"
  project="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.project')")"
  branch="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.branch')")"
  task="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.task')")"

  if [[ -n "${_AP_F_LAUNCH:-}" ]]; then
    _ap_header_launch "$id" "$agent" "$project" "$branch" "${task:-$label}" "$cwd" "$dir" "$model_requested"
    return 0
  fi
  if [[ -n "$project" ]]; then title="$project${branch:+ ${_AP_SEP} $branch}"
  elif [[ -n "$label" ]]; then title="$label"
  else title="run $id"; fi
  _ap_hr
  printf '%s%s%s\n' "$_AP_HEAD" "$_AP_M_HEAD $title" "$_AP_RESET"
  if [[ -n "$task" ]]; then
    _ap_field "task" "$(_ap_shorten "$task" $((_AP_WIDTH - 10)))"
  elif [[ -n "$label" && -n "$project" ]]; then
    _ap_field "task" "$(_ap_shorten "$label" $((_AP_WIDTH - 10)))"
  fi
  _ap_field "run" "$id${agent:+ ${_AP_SEP} $agent}"
  if [[ -n "$model_requested" ]]; then
    model_src=""
    if [[ -n "$model_source" ]]; then
      model_src=" ${_AP_DIM}(from $model_source)${_AP_RESET}"
    fi
    printf '  %smodel%s   requested: %s%s\n' "$_AP_DIM" "$_AP_RESET" "$model_requested" "$model_src"
  else
    printf '  %smodel%s   requested: none %s %s default\n' "$_AP_DIM" "$_AP_RESET" "$_AP_DASH" "${agent:-harness}"
  fi
  if [[ -n "$cwd" ]]; then _ap_field "cwd" "$(_ap_path "$cwd")"; fi
  if [[ -n "$dir" ]]; then _ap_field "output" "$(_ap_path "$dir")/"; fi
  _ap_hr
  return 0
}

# agent_present_stream: read the semantic renderer's activity from stdin
# ([tool] ..., [done] ..., [error] ..., [warn] ..., [think] ..., or plain assistant
# text) and print it as it arrives. Non-label bytes are flushed immediately
# so newline-free progress is visible before EOF. No whole-input buffering,
# no cursor movement, no spinner, no timestamps. Assistant text is never
# truncated or rewrapped.
agent_present_stream() {
  _ap_style_init
  local c="" rc
  _AP_PLAIN=""
  _AP_LINE=""
  _AP_ESC_BUF=""
  _AP_STREAM_STARTED=0
  _AP_OPEN_CARDS=0
  _AP_PREV_TODO=0
  _AP_PLAN=() _AP_PLAN_N=0 _AP_ERR_STREAK=0 _AP_RETRIES=0
  _AP_STREAM_HAD_OUTPUT=0
  _AP_STREAM_TRAILING_NEWLINE=1
  _ap_pinned_init
  # Builtin read -n 1: no per-byte subprocess. Flush plain text after each
  # byte so newline-free progress is visible before EOF. Label lines stay
  # held until newline or until they are no longer a recognized prefix.
  # In pinned mode the read times out once a second so the footer's clock
  # moves while the agent is silent; a timeout returns a status above 128
  # and is not EOF. Bash 3.2 returns 1 for both, so there the footer is
  # redrawn only when a line arrives and no timeout is used.
  local tick=0
  if [[ "${_AP_PIN:-0}" == 1 && "${BASH_VERSINFO[0]:-3}" -ge 4 ]]; then tick=1; fi
  while true; do
    c=""
    rc=0
    if (( tick )); then
      IFS= read -r -n 1 -t 1 c || rc=$?
    else
      IFS= read -r -n 1 c || rc=$?
    fi
    if (( rc == 0 )); then
      if [[ -z "$c" ]]; then
        _ap_stream_putc $'\n'
      else
        _ap_stream_putc "$c"
        _ap_stream_flush_plain
      fi
    elif (( rc > 128 )) && [[ "${_AP_PIN:-0}" == 1 ]]; then
      if [[ -n "$c" ]]; then
        _ap_stream_putc "$c"
        _ap_stream_flush_plain
      fi
      _ap_pinned_draw
    else
      if [[ -n "$c" ]]; then
        _ap_stream_putc "$c"
      fi
      break
    fi
  done
  if [[ -n "${_AP_LINE:-}" ]]; then
    if _ap_is_label "$_AP_LINE"; then
      _ap_emit_stream_line "$_AP_LINE"
    else
      # Incomplete prefix or ordinary bracket text: no extra EOF newline.
      _ap_emit_plain "$_AP_LINE"
    fi
    _AP_LINE=""
  fi
  _AP_ESC_BUF=""
  _ap_stream_flush_plain
  _ap_plan_close
  _ap_pinned_exit
  return 0
}

# agent_present_end: read one state.json object (docs/design.md section 6)
# and print the ending card: the outcome word with its mark, the exit
# status, elapsed time, plan progress, tool and error counts, the agent's
# own summary when it gave one, the last error when it failed, and where
# the record is. Nothing here is ever called accepted or reviewed.
agent_present_end() {
  _ap_style_init
  local kind exit_code el ndone total tools errors summary last_error dir word color mark
  local line task
  _ap_read_one_object "end input is not a single state object" || return 2
  kind="$(_ap_scalar "$_AP_PAYLOAD" '.outcome.kind // ""')"
  exit_code="$(_ap_scalar "$_AP_PAYLOAD" '.outcome.exit // ""')"
  el="$(_ap_scalar "$_AP_PAYLOAD" '.elapsed_s // 0')"
  ndone="$(_ap_scalar "$_AP_PAYLOAD" '.todo_counts.done // 0')"
  total="$(_ap_scalar "$_AP_PAYLOAD" '.todo_counts.total // 0')"
  tools="$(_ap_scalar "$_AP_PAYLOAD" '.counts.tools // 0')"
  errors="$(_ap_scalar "$_AP_PAYLOAD" '.counts.errors // 0')"
  summary="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.outcome.summary // ""')")"
  last_error="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.last_error // ""')")"
  dir="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.record.dir // ""')")"
  task="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.task // ""')")"
  if [[ -n "${_AP_F_REPORT:-}" ]]; then
    _ap_end_report "$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.id // ""')")" \
      "$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.agent // ""')")" \
      "$kind" "$exit_code" "$el" "$ndone" "$total" "$tools" "$errors" \
      "$summary" "$last_error" "$dir" "$task"
    return 0
  fi
  case "$kind" in
    success)   word="done";      color="$_AP_OK";   mark="$_AP_M_DONE" ;;
    failed)    word="failed";    color="$_AP_ERR";  mark="$_AP_M_ERR" ;;
    error)     word="failed";    color="$_AP_ERR";  mark="$_AP_M_ERR" ;;
    cancelled) word="cancelled"; color="$_AP_WARN"; mark="$_AP_M_WARN" ;;
    exited)    word="exited";    color="$_AP_DIM";  mark="$_AP_M_IDLE" ;;
    *)         word="ended";     color="$_AP_WARN"; mark="$_AP_M_UNK" ;;
  esac
  line="$word"
  if [[ -n "$exit_code" ]]; then
    if [[ "$kind" == error ]]; then
      line="$line $_AP_SEP exit $exit_code but the harness reported an error"
    else
      line="$line $_AP_SEP exit $exit_code"
    fi
  fi
  line="$line $_AP_SEP $(_ap_duration "$el")"
  if [[ "$total" != 0 && -n "$total" ]]; then line="$line $_AP_SEP plan $ndone/$total done"; fi
  line="$line $_AP_SEP $(_ap_count "$tools" tool)"
  if [[ "$errors" != 0 && -n "$errors" ]]; then line="$line, $(_ap_count "$errors" error)"; fi
  _ap_hr
  printf '%s%s %s%s\n' "$color" "$mark" "$line" "$_AP_RESET"
  if [[ -n "$task" ]]; then _ap_field "task" "$(_ap_shorten "$task" $((_AP_WIDTH - 10)))"; fi
  if [[ -n "$summary" ]]; then _ap_field "summary" "$summary"; fi
  if [[ -n "$last_error" && "$kind" != success ]]; then
    printf '  %serror%s   %s%s%s\n' "$_AP_DIM" "$_AP_RESET" "$_AP_ERR" "$last_error" "$_AP_RESET"
  fi
  if [[ -n "$dir" ]]; then _ap_field "record" "$(_ap_path "$dir")/"; fi
  _ap_hr
  return 0
}

# agent_present_record: read one run_record_inspect JSON object and print a
# compact status view. "completed" means the worker process completed; the
# review advisory appears only when the evidence warrants it, and nothing is
# ever called accepted. Capture and native evidence is shown when material
# and stays visibly unknown when the record does not evidence it. Open state
# does not claim the log is still growing.
agent_present_record() {
  _ap_style_init
  local id dir state exit_code capture capture_exit agent project label
  local receipt startup native_adapter native_terminal native_found problems problem
  local title state_word state_color capture_word native_line review_word log
  local model_requested model_source model_src events_path output_status output_path
  local output_render output_display output_terminal last_message_path
  local stopped_at stopped_reason stopped_note
  _ap_read_one_object "record input is not a single run_record_inspect object" || return 2
  id="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.id')")"
  dir="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.dir')")"
  state="$(_ap_scalar "$_AP_PAYLOAD" '.state')"
  exit_code="$(_ap_scalar "$_AP_PAYLOAD" '.exit')"
  capture="$(_ap_scalar "$_AP_PAYLOAD" '.capture')"
  capture_exit="$(_ap_scalar "$_AP_PAYLOAD" '.capture_exit')"
  agent="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.agent')")"
  project="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.project')")"
  label="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.label')")"
  model_requested="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.model_requested')")"
  model_source="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.model_source')")"
  events_path="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.paths.events')")"
  output_render="$(_ap_scalar "$_AP_PAYLOAD" '.output.render.status')"
  output_display="$(_ap_scalar "$_AP_PAYLOAD" '.output.display.status')"
  output_terminal="$(_ap_scalar "$_AP_PAYLOAD" '.output.terminal.status')"
  output_path="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.output.display.path')")"
  last_message_path="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.output.last_message.path')")"
  receipt="$(_ap_scalar "$_AP_PAYLOAD" '.receipt')"
  stopped_at="$(_ap_scalar "$_AP_PAYLOAD" '.stopped.at // ""')"
  stopped_reason="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.stopped.reason // ""')")"
  stopped_note="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.stopped.note // ""')")"
  startup="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.startup')")"
  native_adapter="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.native.adapter')")"
  native_terminal="$(_ap_scalar "$_AP_PAYLOAD" '.native.terminal')"
  native_found="$(_ap_json "$_AP_PAYLOAD" '(.native.found | if type == "boolean" then tostring elif type == "string" then . else "" end)')"
  log="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.paths.log')")"
  problems="$(_ap_json "$_AP_PAYLOAD" '(.problems | if type == "array" then .[] else empty end)')"

  if [[ -n "$label" ]]; then title="$label"; else title="run $id"; fi
  _ap_hr
  printf '%s%s%s\n' "$_AP_HEAD" "$_AP_M_HEAD $title" "$_AP_RESET"
  _ap_field "run" "$id${agent:+ ${_AP_SEP} $agent}${project:+ ${_AP_SEP} $project}"
  if [[ -n "$model_requested" ]]; then
    model_src=""
    if [[ -n "$model_source" ]]; then
      model_src=" ${_AP_DIM}(from $model_source)${_AP_RESET}"
    fi
    printf '  %smodel%s   requested: %s%s\n' "$_AP_DIM" "$_AP_RESET" "$model_requested" "$model_src"
  else
    printf '  %smodel%s   requested: none' "$_AP_DIM" "$_AP_RESET"
    if [[ -n "$model_source" ]]; then
      printf ' %s %s' "$_AP_DASH" "$model_source"
    elif [[ -n "$agent" ]]; then
      printf ' %s %s default' "$_AP_DASH" "$agent"
    else
      printf ' %s harness default' "$_AP_DASH"
    fi
    printf '\n'
  fi

  state_color="$_AP_DIM"
  state_word="$(_ap_sanitize "$state")"
  case "$state" in
    completed)  state_word="completed ${_AP_DASH} process exit ${exit_code:-?}"; state_color="$_AP_OK" ;;
    failed)     state_word="failed ${_AP_DASH} process exit ${exit_code:-?}"; state_color="$_AP_ERR" ;;
    cancelled)  state_word="cancelled ${_AP_DASH} native turn ended cancelled (process exit ${exit_code:-?})"; state_color="$_AP_WARN" ;;
    incomplete) state_word="incomplete ${_AP_DASH} process exit ${exit_code:-?} but the log is not trusted"; state_color="$_AP_WARN" ;;
    open)       state_word="open ${_AP_DASH} run has not finished; liveness unknown"; state_color="$_AP_HEAD" ;;
    killed)     state_word="killed ${_AP_DASH} recorded pane no longer exists (no exit marker)"; state_color="$_AP_WARN" ;;
    invalid)    state_word="invalid ${_AP_DASH} record cannot be trusted"; state_color="$_AP_ERR" ;;
    missing)    state_word="missing ${_AP_DASH} no record of that id"; state_color="$_AP_ERR" ;;
    "")         state_word="unknown"; state_color="$_AP_ERR" ;;
  esac
  printf '  %sstate%s   %s%s%s\n' "$_AP_DIM" "$_AP_RESET" "$state_color" "$state_word" "$_AP_RESET"

  # Capture evidence: shown whenever it is not simply complete. Open state
  # alone is not evidence that the log is still being written.
  capture_word=""
  case "$capture" in
    complete) : ;;
    unknown)  capture_word="unknown ${_AP_DASH} this record wrote no capture marker (v1)" ;;
    missing)  capture_word="missing ${_AP_DASH} log.txt may be truncated" ;;
    failed)   capture_word="failed (tee exit ${capture_exit:-?}) ${_AP_DASH} log.txt may be truncated" ;;
  esac
  if [[ -n "$capture_word" ]]; then
    printf '  %scapture%s %s\n' "$_AP_DIM" "$_AP_RESET" "$capture_word"
  fi
  if [[ "$state" != "open" && -n "$output_render" ]]; then
    if [[ "$output_render" != "complete" || "$output_display" != "complete" || "$output_terminal" != "complete" ]]; then
      printf '  %s%s%s output degraded %s render=%s display=%s terminal=%s\n' \
        "$_AP_WARN" "$_AP_M_WARN" "$_AP_RESET" "$_AP_DASH" "$output_render" "${output_display:-unknown}" "${output_terminal:-unknown}"
    fi
  fi

  # Native evidence: found=false stays false even if a terminal field is
  # present. An adapter-less empty native object claims nothing.
  native_line=""
  if [[ -n "$native_adapter" ]]; then
    if [[ "$native_found" == "false" ]]; then
      native_line="$native_adapter session store not found ${_AP_DASH} terminal outcome unknown"
    elif [[ -n "$native_terminal" ]]; then
      native_line="$native_adapter session ${_AP_DASH} terminal: $native_terminal"
    else
      native_line="$native_adapter session ${_AP_DASH} terminal outcome not recorded yet"
    fi
  fi
  if [[ -n "$native_line" ]]; then
    printf '  %snative%s  %s\n' "$_AP_DIM" "$_AP_RESET" "$native_line"
  fi

  # Stop receipt: written by agent-run --stop after a verified pane close.
  # One line: when, why, and where the run got to.
  if [[ -n "$stopped_at" ]]; then
    printf '  %sstop%s    %sstopped %s (%s): %s%s\n' \
      "$_AP_DIM" "$_AP_RESET" "$_AP_WARN" "$stopped_at" "$stopped_reason" "$stopped_note" "$_AP_RESET"
  fi

  # Review advisory: completed work with a trustworthy log earns the receipt
  # scan as evidence; anything else claims no review-readiness.
  review_word=""
  if [[ "$state" == "completed" ]]; then
    case "$receipt" in
      present) review_word="receipt present ${_AP_DASH} verify Changed / Verified / Assumptions / Left undone before accepting" ;;
      absent)  review_word="receipt absent ${_AP_DASH} no receipt in the log tail; read the log before accepting" ;;
    esac
  fi
  if [[ -n "$review_word" ]]; then
    printf '  %sreview%s  %s\n' "$_AP_DIM" "$_AP_RESET" "$review_word"
  fi

  if [[ -n "$startup" ]]; then
    printf '  %s%s%s worker never started: %s\n' "$_AP_WARN" "$_AP_M_WARN" "$_AP_RESET" "$startup"
  fi
  if [[ -n "$problems" ]]; then
    while IFS= read -r problem; do
      [[ -z "$problem" ]] && continue
      printf '  %s%s%s %s\n' "$_AP_WARN" "$_AP_M_WARN" "$_AP_RESET" "$(_ap_sanitize "$problem")"
    done <<<"$problems"
  fi

  if [[ -n "$dir" ]]; then _ap_field "output" "$(_ap_path "$dir")/"; fi
  if [[ -n "$log" ]]; then
    _ap_field "log" "$(_ap_path "$log")"
  fi
  if [[ -n "$events_path" ]]; then
    _ap_field "events" "$(_ap_path "$events_path")"
  fi
  if [[ -n "$output_path" ]]; then _ap_field "display" "$(_ap_path "$output_path")"; fi
  if [[ -n "$last_message_path" ]]; then _ap_field "final" "$(_ap_path "$last_message_path")"; fi
  if [[ "$state" == "open" && -n "$id" ]]; then
    _ap_field "follow" "agent-run --follow $id"
  fi
  if [[ "$state" == "killed" && -n "$id" ]]; then
    _ap_field "output" "agent-run --output $id"
  fi
  _ap_hr
  return 0
}

# agent_present_goal: read one goal summary {id,title,state,dir,
# tasks:[{id,agent,state,run?}],counts?,problems?} and print aligned task rows
# plus where to read each result. The goal library's real shape is supported:
# run_record_inspect summaries nested under task.run, task.status alongside
# task.state, a failure.message, and a planner run. This only renders; it
# never mutates goal state.
agent_present_goal() {
  _ap_style_init
  local id title state dir problems problem rows row planner_log next_word
  local -a task_marks task_colors task_ids task_agents task_states
  local -a task_runs task_run_ids task_notes task_failures task_briefs task_owns
  _ap_read_one_object "goal input is not a single goal summary object" || return 2
  id="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.id')")"
  title="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.title')")"
  state="$(_ap_scalar "$_AP_PAYLOAD" '.state')"
  dir="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.dir')")"
  rows="$(printf '%s' "$_AP_PAYLOAD" | jq -r '
    (.tasks | if type == "array" then . else [] end)[] |
    [(.id | if type == "string" or type == "number" then tostring else "" end),
     (.agent | if type == "string" then . else "" end),
     (.state // .status | if type == "string" then . else "" end),
     (.run.state | if type == "string" then . else "" end),
     ((.run.exit // "") | if type == "string" or type == "number" then tostring else "" end),
     (.run.id | if type == "string" then . else "" end),
     (.run.paths.log | if type == "string" then . else "" end),
     (.failure.message | if type == "string" then . else "" end),
     ((.brief // "") | if type == "string" then gsub("[\\t\\n\\r]+"; " ") | if length > 72 then .[0:69] + "..." else . end else "" end),
     (if (.owns | type) == "array" then
        (if (.owns | length) == 0 then "(none)" else (.owns | join(", ")) end)
      else "" end)] | @tsv' 2>/dev/null)" || rows=""
  planner_log="$(_ap_sanitize "$(_ap_scalar "$_AP_PAYLOAD" '.planner.run.paths.log')")"
  problems="$(_ap_json "$_AP_PAYLOAD" '(.problems | if type == "array" then .[] else empty end)')"

  _ap_hr
  if [[ -n "$title" ]]; then
    printf '%s%s%s  %s%s%s\n' "$_AP_HEAD" "$_AP_M_HEAD $title" "$_AP_RESET" "$_AP_DIM" "$id" "$_AP_RESET"
  else
    printf '%s%s%s\n' "$_AP_HEAD" "$_AP_M_HEAD $id" "$_AP_RESET"
  fi

  local goal_word goal_color
  goal_color="$_AP_DIM"
  goal_word="$(_ap_sanitize "$state")"
  case "$state" in
    planning)       goal_word="planning" ;;
    proposal_ready) goal_word="proposal ready" ;;
    running)        goal_word="running"; goal_color="$_AP_HEAD" ;;
    needs_review)   goal_word="needs review"; goal_color="$_AP_OK" ;;
    attention)      goal_word="attention"; goal_color="$_AP_WARN" ;;
    invalid)        goal_word="invalid"; goal_color="$_AP_ERR" ;;
    missing)        goal_word="missing"; goal_color="$_AP_ERR" ;;
    "")             goal_word="unknown"; goal_color="$_AP_ERR" ;;
  esac
  printf '  %sstate%s   %s%s%s\n' "$_AP_DIM" "$_AP_RESET" "$goal_color" "$goal_word" "$_AP_RESET"
  next_word=""
  case "$state" in
    planning)       next_word="agent-run --goal-proposal $id" ;;
    proposal_ready) next_word="agent-run --goal-start $id" ;;
    running)        next_word="agent-run --goal-status $id" ;;
    needs_review)   next_word="review worker diffs; do not treat this as accepted" ;;
    attention)      next_word="inspect problems; do not retry or start again" ;;
  esac
  if [[ -n "$next_word" ]]; then
    _ap_field "next" "$next_word"
  fi
  if [[ -n "$dir" ]]; then _ap_field "record" "$(_ap_path "$dir")/"; fi

  # Task rows: mark, id, agent, state, note — column widths from the data.
  task_marks=() task_colors=() task_ids=() task_agents=() task_states=()
  task_runs=() task_run_ids=() task_notes=() task_failures=()
  task_briefs=() task_owns=()
  local tid tagent tstate trun_exit trun_id trun_log tfailure tbrief towns
  local mark note color w_id=0 w_agent=0 w_state=0
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    tid="$(_ap_sanitize "$(_ap_tsv "$row" 0)")"
    tagent="$(_ap_sanitize "$(_ap_tsv "$row" 1)")"
    tstate="$(_ap_tsv "$row" 2)"
    trun_exit="$(_ap_tsv "$row" 4)"
    trun_id="$(_ap_sanitize "$(_ap_tsv "$row" 5)")"
    trun_log="$(_ap_sanitize "$(_ap_tsv "$row" 6)")"
    tfailure="$(_ap_sanitize "$(_ap_tsv "$row" 7)")"
    tbrief="$(_ap_sanitize "$(_ap_tsv "$row" 8)")"
    towns="$(_ap_sanitize "$(_ap_tsv "$row" 9)")"
    mark="$_AP_M_UNK" color="$_AP_WARN" note=""
    case "$tstate" in
      not_started)   mark="$_AP_M_IDLE" color="$_AP_DIM"  tstate="not started" ;;
      open)          mark="$_AP_M_UNK"  color="$_AP_HEAD" note="liveness unknown" ;;
      completed)     mark="$_AP_M_DONE" color="$_AP_OK"
                     if [[ -n "$trun_exit" ]]; then note="exit $trun_exit"; fi ;;
      failed)        mark="$_AP_M_ERR"  color="$_AP_ERR"
                     if [[ -n "$trun_exit" ]]; then note="exit $trun_exit"; fi ;;
      cancelled)     mark="$_AP_M_WARN" color="$_AP_WARN" ;;
      killed)        mark="$_AP_M_WARN" color="$_AP_WARN" note="pane gone" ;;
      incomplete)    mark="$_AP_M_WARN" color="$_AP_WARN" note="log not trusted" ;;
      launch_failed) mark="$_AP_M_WARN" color="$_AP_WARN" note="never started"; tstate="launch failed" ;;
      invalid)       mark="$_AP_M_ERR"  color="$_AP_ERR" ;;
      missing)       mark="$_AP_M_ERR"  color="$_AP_ERR" ;;
      "")            if [[ -n "$trun_log" ]]; then tstate="unknown"; else continue; fi ;;
    esac
    task_marks+=("$mark") task_colors+=("$color") task_ids+=("$tid")
    task_agents+=("$tagent") task_states+=("$tstate") task_runs+=("$trun_log")
    task_run_ids+=("$trun_id") task_notes+=("$note") task_failures+=("$tfailure")
    task_briefs+=("$tbrief") task_owns+=("$towns")
    if (( ${#tid} > w_id )); then w_id=${#tid}; fi
    if (( ${#tagent} > w_agent )); then w_agent=${#tagent}; fi
    if (( ${#tstate} > w_state )); then w_state=${#tstate}; fi
  done <<<"$rows"

  # Count line, derived from the rows so it cannot contradict them.
  local counts_line="" s c i
  for s in "completed" "failed" "incomplete" "invalid" "launch failed" \
           "cancelled" "killed" "open" "not started"; do
    c=0
    if (( ${#task_states[@]} > 0 )); then
      for (( i=0; i<${#task_states[@]}; i++ )); do
        if [[ "${task_states[$i]}" == "$s" ]]; then c=$((c + 1)); fi
      done
    fi
    if (( c > 0 )); then
      counts_line="${counts_line}${counts_line:+ ${_AP_SEP} }${c} ${s}"
    fi
  done
  if [[ -n "$counts_line" ]]; then
    _ap_field "tasks" "$counts_line"
  fi

  # The table.
  local idx
  if (( ${#task_ids[@]} > 0 )); then
    for (( idx=0; idx<${#task_ids[@]}; idx++ )); do
      printf '  %s%s%s %-*s  %s%-*s  ' \
        "${task_colors[$idx]}" "${task_marks[$idx]}" "$_AP_RESET" \
        "$((w_id + 1))" "${task_ids[$idx]}" \
        "$_AP_DIM" "$w_agent" "${task_agents[$idx]}"
      if [[ -n "${task_notes[$idx]}" ]]; then
        printf '%-*s %s%s%s' "$((w_state + 1))" "${task_states[$idx]}" \
          "$_AP_DIM" "${task_notes[$idx]}" "$_AP_RESET"
      else
        printf '%s' "${task_states[$idx]}"
      fi
      printf '\n'
      if [[ -n "${task_failures[$idx]}" ]]; then
        printf '      %s%s%s\n' "$_AP_WARN" "${task_failures[$idx]}" "$_AP_RESET"
      fi
      if [[ -n "${task_briefs[$idx]}" ]]; then
        printf '      %sbrief%s  %s\n' "$_AP_DIM" "$_AP_RESET" "${task_briefs[$idx]}"
      fi
      if [[ -n "${task_owns[$idx]}" ]]; then
        printf '      %sowns%s   %s\n' "$_AP_DIM" "$_AP_RESET" "${task_owns[$idx]}"
      fi
    done
  fi

  # Where to read results: usable path per dispatched task. Open tasks
  # follow by run id; never emit tail -f.
  local have_results="" w_res=$((w_id + 1))
  if (( w_res < 8 )); then w_res=8; fi
  if (( ${#task_runs[@]} > 0 )); then
    for (( idx=0; idx<${#task_runs[@]}; idx++ )); do
      if [[ -z "${task_runs[$idx]}" && -z "${task_run_ids[$idx]}" ]]; then continue; fi
      if [[ -z "$have_results" ]]; then
        printf '  %sresults%s\n' "$_AP_DIM" "$_AP_RESET"
        have_results=1
      fi
      if [[ -n "${task_runs[$idx]}" ]]; then
        printf '   %-*s  %s%s%s\n' "$w_res" "${task_ids[$idx]}" \
          "$_AP_DIM" "$(_ap_path "${task_runs[$idx]}")" "$_AP_RESET"
      fi
      if [[ "${task_states[$idx]}" == "open" && -n "${task_run_ids[$idx]}" ]]; then
        printf '   %-*s  %sagent-run --follow %s%s\n' "$w_res" "${task_ids[$idx]}" \
          "$_AP_DIM" "${task_run_ids[$idx]}" "$_AP_RESET"
      fi
    done
  fi
  if [[ -n "$planner_log" ]]; then
    if [[ -z "$have_results" ]]; then
      printf '  %sresults%s\n' "$_AP_DIM" "$_AP_RESET"
    fi
    printf '   %-*s  %s%s%s\n' "$w_res" "planner" "$_AP_DIM" "$(_ap_path "$planner_log")" "$_AP_RESET"
  fi

  if [[ -n "$problems" ]]; then
    while IFS= read -r problem; do
      [[ -z "$problem" ]] && continue
      printf '  %s%s%s %s\n' "$_AP_WARN" "$_AP_M_WARN" "$_AP_RESET" "$(_ap_sanitize "$problem")"
    done <<<"$problems"
  fi
  _ap_hr
  return 0
}
