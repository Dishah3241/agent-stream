#!/usr/bin/env bash
# agent-theme.sh: design files for the pane. Sourced by agent-present.sh.
# The same theme files style the Go watcher; the format is in
# themes/README.md and the project setup in docs/spec-themes.md.
#
# _ap_theme_apply runs inside _ap_style_init after the base palette and
# marks are set. It resolves the theme (AGENT_STREAM_THEME and
# AGENT_STREAM_LOUDNESS, else the project's .agent-stream/config.json at the
# git top level of AGENT_STREAM_PROJECT_DIR or the current directory, else
# space at loud), and loads it over the base with one jq call. No color, an
# ASCII terminal, or loudness quiet always mean the base look, which is
# byte for byte what the pane printed before themes existed. A theme never
# changes display.txt or state.json: it only changes this terminal output.
#
# Bash 3.2 compatible: indexed arrays only; glyph lists come from jq as
# arrays of characters, so multibyte glyphs never depend on the locale's
# substring rules.

_AT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _ap_theme_base: the words, glyphs, and switches of the base look. The
# base glyphs are the pane's own marks, so plan rows look as they always
# did.
_ap_theme_base() {
  local id
  for id in ${_AP_EGG_IDS:-}; do unset "_AP_EGG_$id"; done
  _AP_EGG_IDS='' _AP_EGGS_ON=0 _AP_EGGS_DEFAULT=1
  _AP_T_NAME='base'
  _AP_TITLE="$_AP_HEAD" _AP_THINK="$_AP_DIM" _AP_SKYC="$_AP_DIM" _AP_EGGC="$_AP_HEAD"
  _AP_SHIPS=()
  _AP_G_ACTIVE="$_AP_M_HEAD" _AP_G_LIT="$_AP_M_DONE" _AP_G_PENDING="$_AP_M_IDLE" _AP_G_DROP="$_AP_M_DROP"
  _AP_G_LAUNCH='' _AP_G_TRAIL='' _AP_G_AHEAD='' _AP_G_COPEN='' _AP_G_CCLOSE='' _AP_G_GOPEN='' _AP_G_GCLOSE=''
  _AP_G_SKY=() _AP_G_FIELD=()
  _AP_W_TOOL='' _AP_W_DONE='' _AP_W_ERROR='' _AP_W_WARN='' _AP_W_NOTE=''
  _AP_W_THINK='think' _AP_W_WAIT='waiting' _AP_W_STEP='now' _AP_W_PLAN='plan' _AP_W_RUN='run'
  _AP_W_RESULT_OK='' _AP_W_ALTITUDE='plan' _AP_W_QUIET='quiet' _AP_W_REPORT_TITLE='' _AP_W_METRIC='metric' _AP_W_STAGE='stage'
  _AP_WH_TASK='task' _AP_WH_CWD='cwd' _AP_WH_AGENT='run' _AP_WH_OUTPUT='output' _AP_WH_LIFTOFF='' _AP_WH_COUNTDOWN=''
  _AP_WR_SUCCESS='done' _AP_WR_FAILED='failed' _AP_WR_ERROR='failed'
  _AP_WR_CANCELLED='cancelled' _AP_WR_EXITED='exited' _AP_WR_ENDED='ended'
  _AP_BG_KIND='' _AP_BG_DENSITY=9 _AP_GAUGE=''
  _AP_F_CALLSIGNS='' _AP_F_LAUNCH='' _AP_F_REPORT=''
  _AP_CS_NAMES=()
}

# _ap_theme_depth: tc, 256, or 16. AGENT_RUN_COLOR=always means the
# 16-color palette, as in the watcher.
_ap_theme_depth() {
  if [[ "${AGENT_RUN_COLOR:-auto}" == always ]]; then
    printf '16'
  elif [[ "${COLORTERM:-}" == truecolor || "${COLORTERM:-}" == 24bit ]]; then
    printf 'tc'
  elif [[ "${TERM:-}" == *256color* ]]; then
    printf '256'
  else
    printf '16'
  fi
}

# _ap_theme_find SPEC TOP: the theme file for a spec, or nothing.
_ap_theme_find() {
  local spec="$1" top="$2" d dirs
  case "$spec" in
    */*|*.json)
      [[ -f "$spec" ]] && printf '%s' "$spec"
      return 0 ;;
  esac
  if [[ -n "$top" ]]; then
    if [[ "$spec" == project ]]; then
      [[ -f "$top/.agent-stream/theme.json" ]] && printf '%s' "$top/.agent-stream/theme.json"
      return 0
    fi
    if [[ -f "$top/.agent-stream/$spec.json" ]]; then
      printf '%s' "$top/.agent-stream/$spec.json"
      return 0
    fi
    if [[ -f "$top/.agent-stream/theme.json" ]] \
       && jq -e --arg n "$spec" '.name == $n' "$top/.agent-stream/theme.json" >/dev/null 2>&1; then
      printf '%s' "$top/.agent-stream/theme.json"
      return 0
    fi
  fi
  dirs="${AGENT_STREAM_THEMES:-}"
  while [[ -n "$dirs" ]]; do
    d="${dirs%%:*}"
    if [[ "$dirs" == *:* ]]; then dirs="${dirs#*:}"; else dirs=''; fi
    if [[ -n "$d" && -f "$d/$spec.json" ]]; then printf '%s' "$d/$spec.json"; return 0; fi
  done
  if [[ -n "${HOME:-}" && -f "$HOME/.config/agent-stream/themes/$spec.json" ]]; then
    printf '%s' "$HOME/.config/agent-stream/themes/$spec.json"
    return 0
  fi
  if [[ -f "$_AT_DIR/../themes/$spec.json" ]]; then
    printf '%s' "$_AT_DIR/../themes/$spec.json"
  fi
  return 0
}

# _ap_theme_warn MESSAGE: one warning per distinct message per process.
_ap_theme_warn() {
  if [[ "${_AP_THEME_WARNED:-}" != "$1" ]]; then
    _AP_THEME_WARNED="$1"
    printf 'agent-present: %s; using the base look\n' "$1" >&2
  fi
}

# _ap_theme_apply: resolve and load the theme, cached by everything that
# can change the result.
_ap_theme_apply() {
  local spec="${AGENT_STREAM_THEME:-}" loud="${AGENT_STREAM_LOUDNESS:-}" eggs=''
  local projdir="${AGENT_STREAM_PROJECT_DIR:-$PWD}" top='' cfg utf8=0 depth key file out explicit=1
  local ctype="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ "${TERM:-}" != dumb && "$ctype" == *[Uu][Tt][Ff]-8* ]]; then utf8=1; fi
  depth="$(_ap_theme_depth)"
  if command -v git >/dev/null 2>&1; then
    top="$(git -C "$projdir" rev-parse --show-toplevel 2>/dev/null)" || top=''
  fi
  cfg=''
  if [[ -n "$top" && -f "$top/.agent-stream/config.json" ]]; then
    cfg="$(jq -r '[(.theme // "" | tostring), (.loudness // "" | tostring),
                   (if .eggs == true then "1" elif .eggs == false then "0" else "" end),
                   (.schema // "agent-stream/project/1" | tostring)] | @tsv' \
           "$top/.agent-stream/config.json" 2>/dev/null)" || cfg='!'
    if [[ -z "$cfg" || "$cfg" == '!' ]]; then
      _ap_theme_warn ".agent-stream/config.json is not valid JSON"
      cfg=''
    elif [[ "$(_ap_tsv "$cfg" 3)" != "agent-stream/project/1" ]]; then
      _ap_theme_warn ".agent-stream/config.json has the wrong schema"
      cfg=''
    else
      [[ -n "$spec" ]] || spec="$(_ap_tsv "$cfg" 0)"
      [[ -n "$loud" ]] || loud="$(_ap_tsv "$cfg" 1)"
      eggs="$(_ap_tsv "$cfg" 2)"
    fi
  fi
  case "$spec" in ''|auto) spec=space; explicit=0 ;; esac
  [[ -n "$loud" ]] || loud=loud
  key="$spec|$loud|$eggs|$top|$_AP_COLOR|$utf8|$depth|${AGENT_STREAM_EGGS:-}|${AGENT_STREAM_THEMES:-}"
  if [[ "${_AP_THEME_KEY:-}" == "$key" && -n "${_AP_THEME_OUT+set}" ]]; then
    _ap_theme_base
    [[ -z "$_AP_THEME_OUT" ]] || eval "$_AP_THEME_OUT"
    _ap_theme_eggs "$loud" "$eggs"
    return 0
  fi
  _AP_THEME_KEY="$key"
  _AP_THEME_OUT=''
  _ap_theme_base
  case "$loud" in
    loud|balanced) : ;;
    quiet) return 0 ;;
    *) _ap_theme_warn "loudness \"$loud\" is not loud, balanced, or quiet"; return 0 ;;
  esac
  if [[ "$_AP_COLOR" != 1 || "$utf8" != 1 || "$spec" == plain || "$spec" == base ]]; then
    return 0
  fi
  file="$(_ap_theme_find "$spec" "$top")"
  if [[ -z "$file" ]]; then
    if (( explicit )); then _ap_theme_warn "theme \"$spec\" not found"; fi
    return 0
  fi
  if ! out="$(jq -r --arg depth "$depth" -f "$_AT_DIR/agent-theme.jq" "$file" 2>/dev/null)"; then
    _ap_theme_warn "theme file $file is not a valid agent-stream/theme/1 file"
    return 0
  fi
  _AP_THEME_OUT="$out"
  eval "$out"
  _ap_theme_eggs "$loud" "$eggs"
}

# _ap_theme_eggs LOUDNESS PROJECT_EGGS: eggs are on only for a loud theme
# that wants them (or a project that asks), never with AGENT_STREAM_EGGS=0.
_ap_theme_eggs() {
  local want="$_AP_EGGS_DEFAULT"
  [[ -z "$2" ]] || want="$2"
  _AP_EGGS_ON=0
  if [[ "$1" == loud && "$want" == 1 && "${AGENT_STREAM_EGGS:-1}" != 0 && -n "${_AP_EGG_IDS:-}" ]]; then
    _AP_EGGS_ON=1
  fi
}

# _ap_egg ID: an egg's text, or nothing when eggs are off.
_ap_egg() {
  local v="_AP_EGG_$1"
  [[ "${_AP_EGGS_ON:-0}" == 1 && "$1" =~ ^[a-z0-9_]+$ ]] || return 0
  printf '%s' "${!v:-}"
}

# _ap_djb2 STRING: the shared hash, over bytes, kept to 32 bits, in _AP_HASH.
_ap_djb2() {
  local s="$1" i n c h=5381
  local LC_ALL=C
  n=${#s}
  for (( i = 0; i < n; i++ )); do
    printf -v c '%d' "'${s:i:1}"
    (( c < 0 )) && c=$(( c + 256 ))
    h=$(( (h * 33 + c) & 0xFFFFFFFF ))
  done
  _AP_HASH=$h
}

# _ap_callsign ID: NAME-D for the run, the same as the watcher's, or nothing.
_ap_callsign() {
  local id="$1" n
  [[ -n "$id" && -n "${_AP_F_CALLSIGNS:-}" ]] || return 0
  n=${#_AP_CS_NAMES[@]}
  (( n > 0 )) || return 0
  if [[ "$id" == *1701* && -n "$(_ap_egg callsign_1701)" ]]; then
    _ap_egg callsign_1701
    return 0
  fi
  _ap_djb2 "$id"
  printf '%s-%d' "${_AP_CS_NAMES[$(( _AP_HASH % n ))]}" $(( (_AP_HASH / n) % 9 + 1 ))
}

# _ap_ship ID: the escape for the run's callsign color.
_ap_ship() {
  local n=${#_AP_SHIPS[@]}
  if (( n == 0 )); then printf '%s' "$_AP_HEAD"; return 0; fi
  _ap_djb2 "$1"
  printf '%s' "${_AP_SHIPS[$(( _AP_HASH % n ))]}"
}

# _ap_band ROW LEVEL SEED: one row of the theme's Background Math, the full
# rule width, still (the pane never redraws). LEVEL is 0 to 100: elapsed
# time for trails, activity for meters, finished work for the belt.
_ap_band() {
  local row="$1" level="$2" seed="$3" w="$_AP_WIDTH" kind="${_AP_BG_KIND:-}"
  local ns=${#_AP_G_SKY[@]} nf=${#_AP_G_FIELD[@]} density="${_AP_BG_DENSITY:-9}"
  local -a cells
  local col x r g tail k p out='' step filled i
  [[ -n "$kind" ]] && (( ns > 0 )) || return 1
  case "$density" in ''|*[!0-9]*) density=9 ;; esac
  (( density >= 2 )) || density=9
  for (( col = 0; col < w; col++ )); do cells[col]=' '; done
  x=$(( ((seed ^ ((row * 2654435761) & 0xFFFFFFFF)) | 1) & 0xFFFFFFFF ))
  case "$kind" in
    stars|trails)
      tail=0
      if [[ "$kind" == trails ]]; then tail=$(( level * 6 / 100 + 1 )); fi
      for (( col = 0; col < w; col++ )); do
        x=$(( (x * 1103515245 + 12345) & 0xFFFFFFFF ))
        r=$(( x >> 8 ))
        (( r % density == 0 )) || continue
        g=$(( (r >> 8) % ns ))
        if (( tail > 0 && nf > 0 )); then
          for (( k = 1; k <= tail; k++ )); do
            p=$(( col - k ))
            if (( p >= 0 )) && [[ "${cells[p]}" == ' ' ]]; then cells[p]="${_AP_G_FIELD[0]}"; fi
          done
        fi
        cells[col]="${_AP_G_SKY[g]}"
      done ;;
    grid)
      step=$density
      for (( col = 0; col < w; col++ )); do
        if (( row % 2 == 0 && col % (step * 2) == 0 && ns > 1 )); then cells[col]="${_AP_G_SKY[1]}"
        elif (( row % 2 == 0 && col % step == 0 )); then cells[col]="${_AP_G_SKY[0]}"
        elif (( col % (step * 2) == 0 )); then cells[col]="${_AP_G_SKY[0]}"
        fi
      done ;;
    meters)
      (( nf > 1 )) || return 1
      for (( col = 0; col < w; col += 2 )); do
        x=$(( ((x ^ col) * 1103515245 + 12345) & 0xFFFFFFFF ))
        i=$(( (level * 75 / 100 + ((x >> 8) % 100) * 25 / 100) * (nf - 1) / 100 ))
        (( i > 0 )) && cells[col]="${_AP_G_FIELD[i]}"
      done ;;
    belt)
      step=$density
      filled=$(( level * (w / step) / 100 ))
      for (( col = 0; col < w; col++ )); do
        (( nf > 0 )) && cells[col]="${_AP_G_FIELD[0]}"
      done
      for (( i = 0; i * step < w; i++ )); do
        if (( i < filled && ns > 1 )); then cells[i*step]="${_AP_G_SKY[1]}"; else cells[i*step]="${_AP_G_SKY[0]}"; fi
      done ;;
    *) return 1 ;;
  esac
  for (( col = 0; col < w; col++ )); do out="$out${cells[col]}"; done
  printf '%s%s%s\n' "$_AP_SKYC" "$out" "$_AP_RESET"
}

# _ap_gauge STATUSES WIDTH: plan progress the theme's way. STATUSES is one
# letter per item: d done, a active, p pending, x dropped.
_ap_gauge() {
  local st="$1" max="$2" n=${#1} done=0 active=0 i c out='' w inner f label side right
  (( n > 0 )) || return 0
  for (( i = 0; i < n; i++ )); do
    case "${st:i:1}" in d|x) done=$((done + 1)) ;; a) active=1 ;; esac
  done
  case "${_AP_GAUGE:-}" in
    trajectory)
      if (( n + (n - 1) * 2 > max )); then
        f=$(( done * (max - 1) / n ))
        _ap_repeat out "$_AP_G_TRAIL" "$f"
        out="$_AP_OK$out$_AP_RESET"
        if (( done < n )); then
          _ap_repeat c "$_AP_G_AHEAD" $(( max - 1 - f ))
          out="$out$_AP_HEAD$_AP_G_ACTIVE$_AP_RESET$_AP_DIM$c$_AP_RESET"
        else
          out="$out$_AP_OK$_AP_G_LIT$_AP_RESET"
        fi
      else
        for (( i = 0; i < n; i++ )); do
          c="${st:i:1}"
          case "$c" in
            d) out="$out$_AP_OK$_AP_G_LIT$_AP_RESET" ;;
            a) out="$out$_AP_HEAD$_AP_G_ACTIVE$_AP_RESET" ;;
            x) out="$out$_AP_DIM$_AP_G_DROP$_AP_RESET" ;;
            *) out="$out$_AP_DIM$_AP_G_PENDING$_AP_RESET" ;;
          esac
          (( i == n - 1 )) && break
          if [[ "$c" == d ]]; then out="$out$_AP_OK$_AP_G_TRAIL$_AP_G_TRAIL$_AP_RESET"
          else out="$out$_AP_DIM$_AP_G_AHEAD$_AP_G_AHEAD$_AP_RESET"; fi
        done
      fi ;;
    exposure)
      w=$max; (( w > 24 )) && w=24; (( w < 4 )) && w=4
      local nf=${#_AP_G_FIELD[@]} cells=0
      (( nf >= 2 )) || return 0
      cells=$(( done * w * 4 / n ))
      for (( i = 0; i < w; i++ )); do
        f=$(( cells - i * 4 ))
        if (( f >= 4 )); then out="$out${_AP_G_FIELD[nf-1]}"
        elif (( f > 0 )); then out="$out${_AP_G_FIELD[f * (nf - 1) / 4]}"
        else out="$out${_AP_G_FIELD[0]}"; fi
      done
      out="$_AP_OK$out$_AP_RESET" ;;
    dimension)
      label=" $done of $n "
      w=$max; (( w > 40 )) && w=40; (( w < ${#label} + 4 )) && w=$(( ${#label} + 4 ))
      side=$(( (w - ${#label} - 2) / 2 )); (( side < 1 )) && side=1
      right=$(( w - ${#label} - 2 - side - 1 )); (( right < 0 )) && right=0
      _ap_repeat c "$_AP_G_TRAIL" $(( side - 1 ))
      _ap_repeat f "$_AP_G_TRAIL" "$right"
      out="$_AP_HEAD|<$c$label$f>|$_AP_RESET" ;;
    fill)
      w=$max; (( w > 16 )) && w=16; (( w < 5 )) && w=5
      inner=$(( w - 2 ))
      f=$(( done * inner / n ))
      _ap_repeat c "$_AP_G_LIT" "$f"
      _ap_repeat label "$_AP_G_PENDING" $(( inner - f ))
      if (( active )); then out="$_AP_HEAD"; else out="$_AP_OK"; fi
      out="$_AP_DIM${_AP_G_GOPEN:-[}$_AP_RESET$out$c$label$_AP_RESET$_AP_DIM${_AP_G_GCLOSE:-]}$_AP_RESET" ;;
    *) out="$done/$n" ;;
  esac
  printf '%s' "$out"
}

# _ap_card_open TITLE: "╭─ TITLE ─────" across the rule width, in the
# theme's dim color with the title in its title color.
_ap_card_open() {
  local title="$1" fill n
  n=$(( _AP_WIDTH - ${#title} - 4 ))
  (( n < 3 )) && n=3
  _ap_repeat fill "$_AP_H" "$n"
  printf '%s%s%s%s %s%s%s %s%s%s\n' "$_AP_DIM" "${_AP_G_COPEN:-$_AP_TL}" "$_AP_H" "$_AP_RESET" \
    "$_AP_TITLE" "$title" "$_AP_RESET" "$_AP_DIM" "$fill" "$_AP_RESET"
}

_ap_card_close() {
  local fill
  _ap_repeat fill "$_AP_H" $(( _AP_WIDTH - 1 ))
  printf '%s%s%s%s\n' "$_AP_DIM" "${_AP_G_CCLOSE:-$_AP_BL}" "$fill" "$_AP_RESET"
}

# _ap_tfield LABEL TEXT: a header line whose label column fits the theme's
# longest header label, so "telescope" lines up with "site".
_ap_tfield() {
  local w=7 l
  for l in "$_AP_WH_TASK" "$_AP_WH_CWD" "$_AP_WH_AGENT" "$_AP_WH_OUTPUT"; do
    (( ${#l} > w )) && w=${#l}
  done
  printf '  %s%-*s%s %s\n' "$_AP_DIM" "$w" "$1" "$_AP_RESET" "$2"
}

# _ap_header_launch ID AGENT PROJECT BRANCH TASK CWD DIR MODEL: the themed
# header: a band of the theme's background, a card titled with the run's
# callsign, and the facts as a countdown (space) or labelled lines.
_ap_header_launch() {
  local id="$1" agent="$2" project="$3" branch="$4" task="$5" cwd="$6" dir="$7" model="$8"
  local cs title steps s1 s2 s3 s4 label
  _ap_djb2 "${id:-run}"
  _ap_band 0 0 "$_AP_HASH" || true
  cs="$(_ap_callsign "$id")"
  title="${project:-run $id}${branch:+ $_AP_SEP $branch}"
  [[ -z "$agent" ]] || title="$agent $_AP_SEP $title"
  if [[ -n "$cs" ]]; then
    title="$cs $title"
  fi
  _ap_card_open "$title"
  steps="$_AP_WH_COUNTDOWN"
  s1="${steps%% *}"; steps="${steps#"$s1"}"; steps="${steps# }"
  s2="${steps%% *}"; steps="${steps#"$s2"}"; steps="${steps# }"
  s3="${steps%% *}"; steps="${steps#"$s3"}"; steps="${steps# }"
  s4="${steps%% *}"
  if [[ -n "$task" ]]; then _ap_tfield "$_AP_WH_TASK" "$(_ap_shorten "$task" $((_AP_WIDTH - 14)))"; fi
  label="${model:-default model}"
  if [[ -n "$s1" ]]; then
    printf '  %s%-6s%s %s%-8s%s %s\n' "$_AP_HEAD" "$s1" "$_AP_RESET" "$_AP_DIM" "$_AP_WH_CWD" "$_AP_RESET" "$(_ap_path "$cwd")"
    printf '  %s%-6s%s %s%-8s%s %s\n' "$_AP_HEAD" "$s2" "$_AP_RESET" "$_AP_DIM" "$_AP_WH_AGENT" "$_AP_RESET" "${agent:-agent} $_AP_SEP $label"
    printf '  %s%-6s%s %s%-8s%s %s/\n' "$_AP_HEAD" "$s3" "$_AP_RESET" "$_AP_DIM" "$_AP_WH_OUTPUT" "$_AP_RESET" "$(_ap_path "$dir")"
    printf '  %s%-6s%s %s%s%s %s\n' "$_AP_HEAD" "$s4" "$_AP_RESET" "$_AP_HEAD" "${_AP_G_LAUNCH:-$_AP_M_HEAD}" "$_AP_RESET" "${_AP_WH_LIFTOFF:-start}"
  else
    if [[ -n "$cwd" ]]; then _ap_tfield "$_AP_WH_CWD" "$(_ap_path "$cwd")"; fi
    _ap_tfield "$_AP_WH_AGENT" "${agent:-agent} $_AP_SEP $label"
    if [[ -n "$dir" ]]; then _ap_tfield "$_AP_WH_OUTPUT" "$(_ap_path "$dir")/"; fi
    if [[ -n "$_AP_WH_LIFTOFF" ]]; then
      printf '  %s%s%s %s\n' "$_AP_HEAD" "${_AP_G_LAUNCH:-$_AP_M_HEAD}" "$_AP_RESET" "$_AP_WH_LIFTOFF"
    fi
  fi
  _ap_hr
}

# _ap_end_egg KIND EL TOOLS ERRORS DONE TOTAL: the ending's easter egg text.
_ap_end_egg() {
  local kind="$1" el="$2" tools="$3" errs="$4" done="$5" total="$6" e
  [[ "${_AP_EGGS_ON:-0}" == 1 ]] || return 0
  if (( el >= 86400 )); then
    e="$(_ap_egg sol)"
    if [[ -n "$e" ]]; then printf '%s' "${e//\{sol\}/$(( el / 86400 + 1 ))}"; return 0; fi
  fi
  if [[ "$kind" == failed || "$kind" == error ]] && (( total > 0 && done * 2 >= total )); then
    e="$(_ap_egg seldon_crisis)"; [[ -z "$e" ]] || { printf '%s' "$e"; return 0; }
  fi
  if [[ "$kind" == success ]] && (( errs >= 10 )); then
    e="$(_ap_egg bugs)"; [[ -z "$e" ]] || { printf '%s' "$e"; return 0; }
  fi
  if [[ "$kind" == success ]] && (( total >= 5 && done == total && errs == 0 )); then
    e="$(_ap_egg amaze)"; [[ -z "$e" ]] || { printf '%s' "$e"; return 0; }
  fi
  if (( tools == 42 )); then
    e="$(_ap_egg answer_42)"; [[ -z "$e" ]] || { printf '%s' "$e"; return 0; }
  fi
  if [[ "$kind" == success ]] && (( errs >= 3 )); then
    e="$(_ap_egg science_it)"; [[ -z "$e" ]] || { printf '%s' "$e"; return 0; }
  fi
  if [[ "$kind" == success ]] && (( el >= 3600 )); then
    e="$(_ap_egg seldon_approves)"; [[ -z "$e" ]] || { printf '%s' "$e"; return 0; }
  fi
  return 0
}

# _ap_end_report: the themed ending, from the state fields agent_present_end
# already read (passed in order).
_ap_end_report() {
  local id="$1" agent="$2" kind="$3" exit_code="$4" el="$5" ndone="$6" total="$7"
  local tools="$8" errors="$9" summary="${10}" last_error="${11}" dir="${12}" task="${13}"
  local cs title word color mark line st='' k egg tword level
  case "$kind" in
    success)   word="$_AP_WR_SUCCESS";   color="$_AP_OK";   mark="$_AP_M_DONE" ;;
    failed)    word="$_AP_WR_FAILED";    color="$_AP_ERR";  mark="$_AP_M_ERR" ;;
    error)     word="$_AP_WR_ERROR";     color="$_AP_ERR";  mark="$_AP_M_ERR" ;;
    cancelled) word="$_AP_WR_CANCELLED"; color="$_AP_WARN"; mark="$_AP_M_WARN" ;;
    exited)    word="$_AP_WR_EXITED";    color="$_AP_DIM";  mark="$_AP_M_IDLE" ;;
    *)         word="$_AP_WR_ENDED";     color="$_AP_WARN"; mark="$_AP_M_UNK"; kind="${kind:-ended}" ;;
  esac
  cs="$(_ap_callsign "$id")"
  title="${_AP_W_REPORT_TITLE:-report}"
  [[ -z "$cs" ]] || title="$title $_AP_SEP $cs"
  [[ -z "$agent" ]] || title="$title $agent"
  _ap_card_open "$title"
  line="$kind"
  if [[ -n "$exit_code" ]]; then
    if [[ "$kind" == error ]]; then line="$line $_AP_SEP exit $exit_code but the harness reported an error"
    else line="$line $_AP_SEP exit $exit_code"; fi
  fi
  line="$line $_AP_SEP $(_ap_duration "$el")"
  _ap_box_side "$color$mark $word$_AP_RESET  $line"
  if [[ "$total" != 0 && -n "$total" ]]; then
    if [[ -n "$_AP_GAUGE" ]]; then
      for (( k = 0; k < total; k++ )); do
        if (( k < ndone )); then st="${st}d"; else st="${st}p"; fi
      done
      _ap_box_side "$(_ap_gauge "$st" 30)  $_AP_DIM$_AP_W_ALTITUDE $ndone/$total$_AP_RESET"
    else
      _ap_box_side "plan $ndone/$total done"
    fi
  fi
  tword="${_AP_W_TOOL:-tool}"
  line="$(_ap_count "$tools" "$tword")"
  if [[ "$errors" != 0 && -n "$errors" ]]; then line="$line, $(_ap_count "$errors" "${_AP_W_ERROR:-error}")"; fi
  _ap_box_side "$line"
  if [[ -n "$task" ]]; then _ap_box_side "$_AP_DIM$_AP_WH_TASK$_AP_RESET  $(_ap_shorten "$task" $((_AP_WIDTH - 14)))"; fi
  if [[ -n "$summary" ]]; then _ap_box_side "${_AP_DIM}summary$_AP_RESET  $summary"; fi
  if [[ -n "$last_error" && "$kind" != success ]]; then
    _ap_box_side "${_AP_DIM}error$_AP_RESET  $_AP_ERR$last_error$_AP_RESET"
  fi
  egg="$(_ap_end_egg "$kind" "$el" "$tools" "$errors" "$ndone" "$total")"
  [[ -z "$egg" ]] || _ap_box_side "$_AP_EGGC$egg$_AP_RESET"
  if [[ -n "$dir" ]]; then _ap_box_side "$_AP_DIM$_AP_WH_OUTPUT$_AP_RESET  $(_ap_path "$dir")/"; fi
  _ap_card_close
  level=0
  case "$_AP_BG_KIND" in
    trails) level=$(( el * 100 / 21600 )); (( level > 100 )) && level=100 ;;
    belt) if (( total > 0 )); then level=$(( ndone * 100 / total )); fi ;;
    meters) level=20 ;;
  esac
  _ap_djb2 "${id:-run}"
  _ap_band 1 "$level" "$_AP_HASH" || true
  return 0
}
