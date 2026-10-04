# agent-theme.jq: turn one theme file (themes/README.md) into shell
# assignments for lib/agent-theme.sh. Input is the theme JSON; $depth is
# "tc" (true color), "256", or "16". Output is eval-safe: every value is
# @sh-quoted, every string has control bytes stripped, and only known keys
# become variables (egg ids must match ^[a-z0-9_]+$). A file with the wrong
# schema is an error, so the caller falls back to the base look.

def strip: if type == "string" then gsub("[\u0000-\u001f\u007f]"; "") else "" end;

def hexval: ascii_downcase | explode
  | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));

def rgb: ltrimstr("#") | select(test("^[0-9A-Fa-f]{6}$"))
  | [.[0:2], .[2:4], .[4:6]] | map(hexval) | map(tostring) | join(";");

# sgr(color): the escape for a color role at the requested depth, with the
# theme's own fallbacks: true color, then 256, then 16.
def sgr($c):
  ($c // {}) as $c
  | ([ (if $depth == "tc" and (($c.hex // "") | type) == "string" and ($c.hex | rgb?) != null
          then "38;2;" + ($c.hex | rgb)
        elif ($depth == "tc" or $depth == "256") and (($c.ansi256 | type) == "number") and $c.ansi256 >= 0 and $c.ansi256 <= 255
          then "38;5;" + ($c.ansi256 | floor | tostring)
        elif ($c.ansi | type) == "number" and $c.ansi >= 0 and $c.ansi <= 15
          then (if $c.ansi < 8 then 30 + $c.ansi else 82 + $c.ansi end | floor | tostring)
        else empty end),
       (if $c.bold == true then "1" else empty end),
       (if $c.faint == true then "2" else empty end) ] | join(";")) as $p
  | if $p == "" then "" else "\u001b[" + $p + "m" end;

def assign($name; $value): "\($name)=\($value | strip | @sh)";
def array($name; $list): "\($name)=(" + ($list | map(strip | @sh) | join(" ")) + ")";
def chars: strip | explode | map([.] | implode);

if .schema != "agent-stream/theme/1" then
  error("schema \(.schema // "missing"), want agent-stream/theme/1")
else . end
| . as $t
| ($t.colors // {}) as $col
| ($t.glyphs.unicode // {}) as $g
| ($t.words // {}) as $w
| ($t.features // {}) as $f
| [ assign("_AP_T_NAME"; $t.name // "theme"),
    # Colors: the pane's five roles keep their names; four more are new.
    (if $col.accent then "_AP_HEAD=\(sgr($col.accent) | @sh)" else empty end),
    (if $col.dim then "_AP_DIM=\(sgr($col.dim) | @sh)" else empty end),
    (if $col.ok then "_AP_OK=\(sgr($col.ok) | @sh)" else empty end),
    (if $col.warn then "_AP_WARN=\(sgr($col.warn) | @sh)" else empty end),
    (if $col.err then "_AP_ERR=\(sgr($col.err) | @sh)" else empty end),
    (if $col.title then "_AP_TITLE=\(sgr($col.title) | @sh)" else empty end),
    (if $col.think then "_AP_THINK=\(sgr($col.think) | @sh)" else empty end),
    (if $col.sky then "_AP_SKYC=\(sgr($col.sky) | @sh)" else empty end),
    (if $col.egg then "_AP_EGGC=\(sgr($col.egg) | @sh)" else empty end),
    "_AP_SHIPS=(" + ([($col.ships // [])[] | sgr(.) | @sh] | join(" ")) + ")",
    # Glyphs: the theme's unicode set (themes only apply on UTF-8 terminals).
    (if $g.active then assign("_AP_G_ACTIVE"; $g.active) else empty end),
    (if $g.lit then assign("_AP_G_LIT"; $g.lit) else empty end),
    (if $g.pending then assign("_AP_G_PENDING"; $g.pending) else empty end),
    (if $g.dropped then assign("_AP_G_DROP"; $g.dropped) else empty end),
    assign("_AP_G_LAUNCH"; $g.launch // ""),
    assign("_AP_G_TRAIL"; $g.trail // ""),
    assign("_AP_G_AHEAD"; $g.ahead // ""),
    assign("_AP_G_COPEN"; $g.card_open // ""),
    assign("_AP_G_CCLOSE"; $g.card_close // ""),
    assign("_AP_G_GOPEN"; $g.gauge_open // ""),
    assign("_AP_G_GCLOSE"; $g.gauge_close // ""),
    array("_AP_G_SKY"; ($g.sky // "") | chars),
    array("_AP_G_FIELD"; ($g.field // "") | chars),
    # Words.
    ( [["tool","TOOL"],["done","DONE"],["error","ERROR"],["warn","WARN"],["note","NOTE"],
       ["think","THINK"],["wait","WAIT"],["step","STEP"],["plan","PLAN"],["run","RUN"],
       ["result_ok","RESULT_OK"],["altitude","ALTITUDE"],["quiet","QUIET"],
       ["report_title","REPORT_TITLE"]][]
      | select(($w[.[0]] | type) == "string") | assign("_AP_W_" + .[1]; $w[.[0]]) ),
    ( ($w.header // {}) | to_entries[] | select(.key | test("^(task|cwd|agent|output|liftoff|countdown)$"))
      | assign("_AP_WH_" + (.key | ascii_upcase); .value) ),
    ( ($w.report // {}) | to_entries[] | select(.key | test("^(success|failed|error|cancelled|exited|ended)$"))
      | assign("_AP_WR_" + (.key | ascii_upcase); .value) ),
    # Drawing.
    assign("_AP_BG_KIND"; if ($t.background.kind // "") == "none" then "" else ($t.background.kind // "") end),
    assign("_AP_BG_DENSITY"; ($t.background.density // 9) | tostring),
    assign("_AP_GAUGE"; $t.gauge // ""),
    assign("_AP_F_CALLSIGNS"; if $f.callsigns == true then "1" else "" end),
    assign("_AP_F_LAUNCH"; if $f.launch_header == true then "1" else "" end),
    assign("_AP_F_REPORT"; if $f.mission_report == true then "1" else "" end),
    array("_AP_CS_NAMES"; [($t.callsigns.names // [])[] | strip | select(length > 0)]),
    assign("_AP_EGGS_DEFAULT"; if $t.eggs_default == false then "0" else "1" end),
    assign("_AP_EGG_IDS"; [($t.eggs // {}) | keys[] | select(test("^[a-z0-9_]+$"))] | join(" ")),
    ( ($t.eggs // {}) | to_entries[] | select(.key | test("^[a-z0-9_]+$"))
      | assign("_AP_EGG_" + .key; .value) )
  ][]
