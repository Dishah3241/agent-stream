# Themes

A theme is a design file. The look you get with no theme is the **base**: the quiet palette, marks, and words built into `lib/agent-present.sh` and `cmd/agent-stream-watch`, byte for byte what agent-stream printed before themes existed. A theme file overrides only what it names. The Bash pane and the Go watcher read the same file, so one theme styles both.

Themes change presentation only. `display.txt`, `state.json`, and the activity line protocol never change with the theme, and every state keeps its mark and a plain word next to the themed one, so nothing depends on color or art alone.

## The designs

| Theme | For | Background | Gauge | Callsigns | Eggs |
|---|---|---|---|---|---|
| `space` | agent-stream, and the default | starfield | flight path with a rocket | star names (ANTARES-4) | book sci-fi: Hitchhiker's, Foundation, Three-Body, Project Hail Mary, Dune, The Martian, Culture, Murderbot, Neuromancer |
| `observatory` | Forge: long jobs | star trails that grow with elapsed time | a photographic plate developing | telescopes (SUBARU-8) | astronomy, Three-Body, Asimov's "Nightfall" |
| `blueprint` | Miini: the planner | measured graph-paper grid | a dimension line, `\|<── 2 of 4 ──>\|` | drawing numbers (PLAN-7) | Ender's Game, Foundation, Dune |
| `radio` | Air: interviews and the daily brief | VU meters | notes on a staff | call letters (WWAVE-7) | radio and broadcast nods |
| `bottling` | PC: the edamame water company's workstation | a moving production line | a bottle filling | line names (BEAN-7) | gentle factory nods, off by default |

`tests/fixtures/agent-present/preview.sh` shows all of them in a real terminal; `agent-stream watch --theme NAME` shows the watcher.

## Choosing a theme

A project commits `.agent-stream/config.json` at its git top level:

```json
{ "schema": "agent-stream/project/1", "theme": "observatory", "loudness": "loud", "eggs": true }
```

- `theme`: a theme name, `project` (the project's own `.agent-stream/theme.json`), `plain`, or a path. Default `space`.
- `loudness`: `loud` (backgrounds, motion in the watcher, easter eggs), `balanced` (the theme without motion or eggs), `quiet` (the base look). Default `loud`.
- `eggs`: optional; overrides the theme's own default.

Resolution, first match wins: `AGENT_STREAM_THEME` and `AGENT_STREAM_LOUDNESS` (the watcher's `--theme` and `--loudness`), then the project's config, then `space` at `loud`. The capture layer reads the project from the run's working directory and records the choice in `state.json` as `theme`, so a watcher elsewhere knows what the run asked for.

The terminal has the last word: no color (`NO_COLOR`, `AGENT_RUN_COLOR=never`, a pipe), `TERM=dumb`, or a non-UTF-8 locale always mean the base look.

A theme name is looked up as `.agent-stream/NAME.json` in the project, then as the project's `.agent-stream/theme.json` if its `name` matches (so a project can override a shipped theme), then in each directory of `AGENT_STREAM_THEMES` (colon-separated), `~/.config/agent-stream/themes`, and this directory. A missing or invalid file falls back to the base with one warning on stderr. `AGENT_STREAM_EGGS=0` (or the watcher's `--no-eggs`) turns eggs off everywhere.

## Format (`agent-stream/theme/1`)

```json
{
  "schema": "agent-stream/theme/1",
  "name": "space",
  "description": "one line",
  "eggs_default": true,
  "colors":     { "ROLE": { "hex": "#5CE1E6", "ansi256": 80, "ansi": 6, "bold": false, "faint": false }, "ships": [ ... ] },
  "glyphs":     { "unicode": { "KEY": "➤" }, "ascii": { "KEY": ">" } },
  "words":      { "KEY": "text", "header": { ... }, "states": { ... }, "report": { ... }, "columns": { ... } },
  "background": { "kind": "stars", "density": 9 },
  "gauge":      "trajectory",
  "features":   { "callsigns": true, "launch_header": true, "mission_report": true, "twinkle": true, "holding_spinner": true },
  "callsigns":  { "names": [ "VEGA", ... ] },
  "eggs":       { "EGG_ID": "text" }
}
```

**Colors.** Roles: `accent` (headings, active items), `dim` (metadata, borders), `ok`, `warn`, `err`, `title`, `think`, `sky` (the background), `egg`, and `ships` (a list; each callsign gets one). Each role gives a true-color `hex`, a 256-color index, and a 16-color index (0 to 15); the terminal's depth picks the theme's own value, never a computed one. `bold` and `faint` are attributes. `AGENT_RUN_COLOR=always` means the 16-color palette.

**Glyphs.** Two sets; the ASCII set is used only by the watcher (the pane shows the base look on ASCII terminals). Keys: `active`, `lit` (a finished plan item), `pending`, `dropped`, `launch`, `trail`, `ahead`, `card_open`, `card_close` (header and report cards), `gauge_open`, `gauge_close` (the ends of a fill gauge), `sky` (background glyphs), `field` (background fill: trail dust, meter bars, the belt, exposure shades), `orbit` (spinner frames), and the watcher's `step`, `done`, `error`, `warn`, `unknown`, `wait`, `sep`, `ell`, `rule`, `side`, `divider`. Every glyph must be one column wide: emoji such as 🚀 are two wide and multiplexers count them differently, and the tests reject them.

**Words.** Prefixes and labels: `tool`, `done` (a suffix), `error`, `warn`, `note`, `think`, `wait`, `step`, `plan`, `run`, `result_ok`, `altitude` (the gauge label), `quiet`, `fleet_title`, `report_title`. `header`: `task`, `cwd`, `agent`, `output`, `liftoff`, and `countdown` (four steps such as `T-3 T-2 T-1 T-0`, or absent for plain labels). `states`: the state column and footer (`running`, `waiting`, `starting`, `success`, `failed`, `error`, `cancelled`, `exited`, `ended`, `unknown`). `report`: the ending's headline per outcome. `columns`: the fleet headings, including `ship`. An empty string removes the word.

**Background** (Background Math). A generated backdrop, drawn as a band above the header and below the ending in the pane, and behind the fleet in the watcher. Kinds: `stars`, `trails` (tails grow over six hours of elapsed time), `grid`, `meters` (bars follow recent activity), `belt` (filled bottles follow plan progress), `none`. Every kind is a pure function of width, row, a seed from the run or roots, the frame (only when loud, only in the watcher), and that live level, so it looks the same on every redraw.

**Gauge.** How plan progress is drawn: `trajectory`, `exposure`, `dimension`, `fill`, or absent for `done/total`.

**Features.** `callsigns` (NAME-D from `callsigns.names`, by a djb2 hash of the run id, identical in Bash and Go), `launch_header` (the themed header card), `mission_report` (the themed ending card), `twinkle` and `holding_spinner` (watcher motion at the one-second tick, loud only). An unknown feature is an error.

**Eggs.** Each key is a trigger built into the code; the value is the text shown. A theme can rewrite or drop any egg, but cannot invent a trigger. `eggs_default: false` keeps them off unless the project sets `"eggs": true`.

| Egg | Fires when | Where |
|---|---|---|
| `error_streak` | the third error in a row with no success between | pane |
| `three_laws` | the harness result reports denied permissions | pane |
| `chaotic_era` | the third retry wait in one run | pane |
| `spice` | a compaction wait | pane |
| `answer_42` | a run ends with exactly 42 tool calls | ending, watcher |
| `seldon_crisis` | a run fails after at least half its plan was done | ending, watcher |
| `seldon_approves` | a run succeeds after at least an hour | ending, watcher |
| `bugs` | a run succeeds despite ten or more errors | ending, watcher |
| `amaze` | five or more plan items all done with no errors | ending, watcher |
| `science_it` | three or more errors, then success | ending |
| `sol` | a run lasted a day or more (`{sol}` is the day) | ending, watcher |
| `midnight` | a run started and ended on different days | watcher |
| `dark_forest` | an open run has been quiet for ten minutes | watcher |
| `litany` | a wait has lasted ten minutes | watcher |
| `wallfacer` | one run has been the only open run for thirty minutes | watcher |
| `fist_my_bump` | two runs succeeded within ten seconds of each other | watcher |
| `dead_channel` | the watcher has no open runs | watcher |
| `callsign_1701` | the run id contains 1701 (replaces the callsign) | both |
| `hyperspace` | the hidden key sequence ↑↑↓↓←→←→ b a | watcher |

Eggs are on only for a loud theme on a color, UTF-8 terminal; they never replace a state word or an error, never reach `display.txt` or `state.json`, and fire only on real conditions, so each one has a test.

## Making a new design

Copy a theme, change `name`, and point at it:

```bash
AGENT_STREAM_THEME=./mine.json tests/fixtures/agent-present/preview.sh
agent-stream watch --theme ./mine.json
```

For a project, save it as `.agent-stream/theme.json` and set `"theme": "project"` in `.agent-stream/config.json`.
