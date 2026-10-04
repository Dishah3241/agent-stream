# Themes

A theme is a design file. The look you get with no theme is the **base**: the quiet palette, marks, and words built into `lib/agent-present.sh` and `cmd/agent-stream-watch`. A theme file overrides only what it names; everything it leaves out falls back to the base. The Bash pane and the Go watcher read the same file, so one theme styles both.

Themes change presentation only. `display.txt`, `state.json`, and the activity line protocol never change with the theme, and every state keeps its mark and a word, so nothing depends on color or art alone.

## Choosing a theme

| `AGENT_STREAM_THEME` | Result |
|---|---|
| unset or `auto` | `space` on a color, UTF-8 terminal; the base everywhere else (pipes, `NO_COLOR`, `TERM=dumb`, non-UTF-8 locales) |
| `plain` or `base` | the base look, exactly as before themes existed |
| a name, such as `space` | `NAME.json` from the search path below |
| a path, such as `./mine.json` | that file |

Search path for names: every directory in `AGENT_STREAM_THEMES` (colon-separated), then `~/.config/agent-stream/themes`, then this directory. A file that is missing or not valid JSON falls back to the base with one warning on stderr.

`AGENT_STREAM_EGGS=0` turns the easter eggs off. Eggs are also off whenever color is off or marks are ASCII. The watcher takes `--theme NAME|PATH` and `--no-eggs`.

## Format (`agent-stream/theme/1`)

```json
{
  "schema": "agent-stream/theme/1",
  "name": "space",
  "description": "one line",
  "colors":   { "ROLE": { "hex": "#5CE1E6", "ansi256": 80, "ansi": 6, "bold": false, "faint": false }, "ships": [ ... ] },
  "glyphs":   { "unicode": { "KEY": "➤" }, "ascii": { "KEY": ">" } },
  "words":    { "KEY": "text", "states": { ... }, "report": { ... }, "header": { ... }, "columns": { ... } },
  "features": { "sky": true, "callsigns": true, "trajectory": true, ... },
  "callsigns": { "names": [ "VEGA", ... ] },
  "eggs":     { "EGG_ID": "text" }
}
```

**Colors.** Roles: `accent` (headings, active items), `dim` (metadata, borders), `ok`, `warn`, `err`, `title`, `think`, `sky`, `egg`, and `ships` (a list, one per callsign). Each role gives a true-color `hex`, a 256-color index, and a 16-color index (0 to 15), so the color degrades cleanly on every terminal. `bold` and `faint` are attributes. The base uses the 16-color cyan, faint, green, amber, red.

**Glyphs.** Two sets, `unicode` and `ascii`; ASCII is used for `TERM=dumb` and non-UTF-8 locales. Keys: `active`, `step`, `done`, `error`, `warn`, `unknown`, `pending`, `wait`, `dropped`, `sep`, `ell`, `card_open`, `card_close`, `rule`, `side`, `divider`, `lit` (a finished plan item), `launch`, `trail`, `ahead`, `sky` (a string of star glyphs), `orbit` (spinner frames). Use single-width glyphs: emoji such as 🚀 are double-width and multiplexers count them differently.

**Words.** Prefixes and labels: `tool`, `done`, `error`, `warn`, `note`, `think`, `wait`, `step`, `plan`, `run`, `result_ok`, `altitude`, `quiet`, `fleet_title`, `report_title`; `header` labels (`task`, `cwd`, `agent`, `output`, `liftoff`); `states` (the watcher's state column and footer: `running`, `waiting`, `starting`, `success`, `failed`, `error`, `cancelled`, `exited`, `ended`, `unknown`); `report` (the outcome headline of the ending card); `columns` (fleet headings, including `ship`). An empty string removes the word.

**Features.** `sky` (a seeded star row; `sky_density` is one star per N columns on average), `callsigns` (a stable ship name per run, derived from the run id), `trajectory` (the plan drawn as a flight path), `launch_header` (the countdown header), `mission_report` (the ending as a mission report), `twinkle` and `holding_spinner` (watcher animation at the one-second tick).

**Callsigns.** NAME-D from `callsigns.names`: a djb2 hash of the run id picks the name and the digit, identically in Bash and Go.

**Eggs.** Each key is a trigger built into the code; the value is the text shown. A theme can rewrite or drop any egg, but cannot invent a new trigger. Triggers:

| Egg | Fires when | Where |
|---|---|---|
| `error_streak` | the third error in a row with no success in between | pane |
| `answer_42` | a run ends with exactly 42 tool calls | pane ending, watcher |
| `three_laws` | the harness result reports denied permissions | pane |
| `seldon_crisis` | a run fails after at least half its plan was done | pane ending, watcher |
| `seldon_approves` | a run succeeds after at least an hour | pane ending, watcher |
| `dark_forest` | an open run has been quiet for ten minutes | watcher |
| `chaotic_era` | the third retry wait in one run | pane |
| `bugs` | a run succeeds despite ten or more errors | pane ending, watcher |
| `wallfacer` | one run is the only open run for thirty minutes | watcher |
| `fist_my_bump` | two runs succeed within ten seconds of each other | watcher |
| `amaze` | five or more plan items all done with no errors | pane ending, watcher |
| `sol` | a run has been going for a day or more (`{sol}` is the day) | pane ending, watcher |
| `science_it` | three or more errors, then success | pane ending |
| `spice` | a compaction wait | pane |
| `litany` | a permission or input wait longer than ten minutes | watcher |
| `dead_channel` | the watcher has no open runs | watcher |
| `callsign_1701` | the run id contains 1701 (replaces the callsign) | both |
| `hyperspace` | the hidden key sequence ↑↑↓↓←→←→ b a | watcher |

Eggs never replace the real state word or error text, never reach `display.txt` or `state.json`, and fire only on real conditions, so tests can trigger each one.

## Making a new design

Copy `space.json`, change the name, and set `AGENT_STREAM_THEME` to its path. Keep `schema` as `agent-stream/theme/1`. Check it with the preview:

```bash
AGENT_STREAM_THEME=./mine.json tests/fixtures/agent-present/preview.sh
agent-stream watch --theme ./mine.json
```
