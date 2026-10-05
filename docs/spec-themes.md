# Spec: project themes, Forge telemetry, and the combined board

Status: agreed in an interview with the owner on 2026-10-04. This spec
drives the next four milestones. Where it says "assumption", the owner has
not confirmed the detail; build it as written and flag it in the pull
request.

## 1. Context

Four products run headless agents in Herdr panes, each on its own Herdr
machine. Agents launch other agents through skills that call
`herdr agent run`. Every run already leaves an agent-stream record
(`display.txt`, `state.json`, raw events) and can be watched with the pane
and the watcher.

| Product | What it does | Machine |
|---|---|---|
| agent-stream | this repository's own runs | any |
| Forge | the factory: long-running work and background math | its own Herdr machine |
| Miini | the planner | its own Herdr machine |
| Air | interview manager and daily manager for helper agents | its own Herdr machine |
| PC | the workstation where the owner runs agents by hand for the edamame water company | its own Herdr machine |

The goal: each project looks like itself, chosen by a file committed in its
own repository; Forge's long jobs show progress, liveness, numbers, and
stages; and one board shows every machine's runs together.

## 2. Decisions from the interview

| Question | Decision |
|---|---|
| Where output appears | Herdr panes, one Herdr machine per product |
| What Forge's "background math" is | long-running work and background computation, to be shown, not decoration |
| How products use themes | unique themes, chosen per project |
| Where a project's choice lives | `.agent-stream/config.json` in the project's git repository |
| Where theme files live | both: shipped in `agent-stream/themes/`, and a project's own `.agent-stream/theme.json` wins |
| Cross-machine view | one combined board |
| Board transport | SSH pull |
| How Forge reports numbers | new protocol lines, `[metric]` and `[stage]` |
| What a Forge pane must make obvious | progress and ETA, liveness heartbeat, computation telemetry, stage timeline |
| Forge mood | Observatory |
| Miini mood | Architect blueprint |
| Air mood | Morning radio |
| PC | the owner's agent workstation for the edamame water company |
| PC mood | Bottling plant |
| Loudness | one level per project: `loud`, `balanced`, `quiet` |
| Easter eggs | each theme has its own, fitting its world |
| Default theme | space for agent-stream and for any project without config |
| Charm v2 | migrate the watcher first, then build the themes on v2 |
| Order | themes first, then Forge metrics, then the board |

## 3. Project configuration

A project opts in with a committed folder at its git top level:

```
.agent-stream/
  config.json     required to configure; may be the only file
  theme.json      optional: a design for this project only
```

`config.json`:

```json
{
  "schema": "agent-stream/project/1",
  "theme": "observatory",
  "loudness": "loud"
}
```

- `theme`: a shipped theme name, `project` (use `.agent-stream/theme.json`),
  or `plain`. Default `space`.
- `loudness`: `loud`, `balanced`, or `quiet`. Default `loud`.

**Resolution, first match wins:**

1. `AGENT_STREAM_THEME` and `AGENT_STREAM_LOUDNESS` in the environment
   (the watcher's `--theme` and `--loudness` flags count as environment).
2. The run's project config, read from the git top level of the run's
   working directory (the same detection `run_capture_context` already
   does). The capture layer copies the resolved values into the record as
   `theme` and `loudness` in `header.json`, so the watcher and the board
   style each run the way its own project chose, on any machine.
3. Default: `space`, `loud`.

A theme named in config is looked up as `.agent-stream/<name>.json` in the
project first, then `AGENT_STREAM_THEMES`, then
`~/.config/agent-stream/themes`, then `agent-stream/themes/`. A
`.agent-stream/theme.json` whose `name` matches a shipped theme overrides
that theme for this project (both, as decided).

The terminal still has the last word: color off, `TERM=dumb`, a non-UTF-8
locale, or a pipe means the base look, whatever the config says.
`display.txt` and `state.json` never change with the theme.

**Loudness levels:**

| Level | Theme colors, glyphs, words | Background band | Animation | Easter eggs |
|---|---|---|---|---|
| `loud` | yes | yes | yes (watcher tick) | yes |
| `balanced` | yes | yes, static | no | no |
| `quiet` | no: base look | no | no | no |

## 4. Theme format

As drafted in `themes/README.md` (`agent-stream/theme/1`): colors with
true-color, 256, and 16-color values; unicode and ASCII glyph sets; words;
features; callsign names; eggs as text keyed by built-in trigger. This spec
adds:

- `background`: `{"kind": "...", "density": N}` with kinds `stars`,
  `trails` (slow star trails), `grid` (blueprint lattice), `meters`
  (VU-style bars), `belt` (a moving production line), `none`. These are the
  Background Math generators: pure functions of width, row, seed, and frame,
  and for `meters` and `trails` also of live metrics when the run has them.
- `gauges`: how a theme draws progress (`trajectory`, `exposure`,
  `dimension`, `fill`) so Forge's ETA and PC's fill levels look native.
- `eggs` triggers become per theme; the trigger set grows with the themes
  below. A theme cannot invent a trigger, only text for one.

## 5. The five themes

Every theme keeps the state mark and a plain state word on every line it
restyles. Glyphs must be single-width.

### space (agent-stream, and the default)

Deep Field as already designed: starfield background, star callsigns
(SIRIUS-4), the plan as a flight path with a rocket, "in flight",
"holding", "orbit achieved", "anomaly", "scrubbed". Eggs: the book
sci-fi set (Hitchhiker's, Foundation, Three-Body, Project Hail Mary, Dune,
The Martian, Culture, Murderbot, Neuromancer).

### observatory (Forge)

Long exposures for long jobs. Night-sky indigo, starlight white,
red-light-safe amber for warnings.

- **Background:** `trails`, slow star trails whose length grows with
  elapsed time, so a six-hour run looks like a six-hour exposure.
- **Callsigns:** telescope names (HALE-2, KECK-1, PALOMAR-4).
- **Words:** run start "dome open", tool "exposure", done "frame saved",
  error "cloud cover", wait "tracking", plan "observing plan",
  success "dawn: plates developed", failed "clouded out".
- **Gauges:** `exposure`, a progress bar that fills like a plate developing,
  with ETA shown as "dawn in 2h14m".
- **Liveness:** a heartbeat star that pulses each time a line arrives;
  after ten quiet minutes it dims and the row reads "no light for 12m".
- **Telemetry:** `[metric]` series drawn as sparklines and a "magnitude"
  readout for the latest value; `[stage]` lines as a timeline of exposures
  with their durations.
- **Eggs:** Three-Body (a countdown in the corner when a metric is
  converging; "the universe flickers" on a failure streak), Contact,
  Cosmos, Asimov's "Nightfall" when a run crosses midnight.

### blueprint (Miini)

The plan as a technical drawing. Blueprint blue, white linework, cyan
dimension lines, red for redlines.

- **Background:** `grid`, a measured lattice with tick marks every ten
  columns.
- **Callsigns:** drawing numbers (DWG-104, SHEET-3).
- **Words:** plan "drawing set", tool "draft", done "inked", error
  "redline", wait "awaiting sign-off", step "detail", success "approved
  for construction", failed "returned with redlines".
- **Gauges:** `dimension`, progress drawn as a dimension line
  `|<------ 3 of 5 ------>|`.
- **Plan view:** the plan as a tree with connectors (Lip Gloss tree),
  dependencies shown as leader lines.
- **Eggs:** Ender's Game ("the enemy's gate is down" when a plan is
  reversed), Foundation ("psychohistory" forecast for long plans), Dune
  ("plans within plans" for nested agents).

### radio (Air)

A warm morning broadcast. Studio walnut, on-air red, VU green, cream text.

- **Background:** `meters`, VU bars that move with activity (tool calls
  per minute), still when the agent is quiet.
- **Callsigns:** station call letters (KAIR-3, WAIR-7).
- **Words:** run start "on air", tool "segment", done "wrapped",
  error "dead air", wait "holding for caller", step "now playing",
  plan "rundown", success "signing off", failed "off the air".
- **Daily view:** the day's plan as a show rundown with times; interviews as
  segments with a live "ON AIR" light while one runs.
- **Eggs:** Hitchhiker's radio series, "The War of the Worlds" broadcast on a
  failure cascade, "Pump Up the Volume" style late-night nod for runs after
  midnight, Murderbot's media feed while waiting.

### bottling (PC)

A clean production line for the edamame water company. Edamame green,
clear-water teal, stainless grey.

- **Background:** `belt`, bottles moving along a production line, one
  bottle per finished tool call.
- **Callsigns:** line and batch (LINE-2 BATCH-0417).
- **Words:** run start "line started", tool "fill", done "capped",
  error "spill", wait "line paused", plan "batch sheet", success
  "shipped", failed "recalled", cancelled "line stopped".
- **Gauges:** `fill`, each agent as a bottle that fills with plan progress.
- **Eggs:** Willy Wonka factory nod on 42 filled bottles, Dune's water
  discipline ("not a drop wasted") on a run with zero errors, "Soylent"
  joke on a failed batch (assumption: keep it gentle, it is a client's
  workstation).

## 6. Forge telemetry: `[metric]` and `[stage]`

Two new protocol lines, emitted by agents in their own output on a line of
their own (Forge's skills will instruct agents to print them):

```
[metric] NAME=VALUE [UNIT]        e.g. [metric] residual=0.0031
[stage] I/N NAME                  e.g. [stage] 3/7 integrate
```

- The renderer passes them through as it does `[todo]`; the presenter styles
  them; the state tracker keeps `metrics` (name to latest value, unit, and
  the last 60 samples with timestamps) and `stages` (index, total, name,
  started, ended) in `state.json`.
- **ETA:** from stage and plan progress over elapsed time, shown only after
  two stages or plan items finish, and labelled as a forecast.
- **Heartbeat:** the age of the last display line; the state tracker
  already writes on every label line, so the watcher and board read it from
  `updated_at`.
- **Safety:** names are `[A-Za-z0-9_.-]{1,40}`, values must parse as
  numbers, at most 32 metric names per run; anything else is ignored, never
  printed raw.

This is a protocol change, so the renderer, presenter, state tracker, and
their test files change together (AGENTS.md).

## 7. The combined board

`agent-stream board` runs the watcher's fleet view over every machine.

```json
// ~/.config/agent-stream/board.json
{
  "machines": [
    { "name": "forge", "ssh": "forge.local", "root": "~/.agent-stream/runs" },
    { "name": "miini", "ssh": "miini.local" },
    { "name": "air",   "ssh": "air.local" },
    { "name": "pc",    "ssh": "pc.local" }
  ]
}
```

- **Transport:** one persistent SSH connection per machine (OpenSSH
  `ControlMaster`). Each tick runs one small shell command remotely that
  lists `state.json` modification times and prints the changed ones; the run
  view tails `display.txt` with `tail -c +OFFSET`. Nothing new is installed
  on the machines beyond bash and coreutils.
- **Board layout:** a MACHINE column, rows grouped by machine, each row
  styled with its own project's theme (accent color and callsign); the board
  chrome uses the board's own theme.
- **Nesting:** when a run was started by another agent through
  `herdr agent run`, it is shown under its parent (assumption: Herdr can pass
  the parent run id; see open questions).
- **Failure:** an unreachable machine shows one "no signal" row with the
  last time it answered; the rest of the board keeps working.
- **Read-only:** the board never writes to any machine.

## 8. Milestones

Each milestone is a pull request that passes CI on Linux and macOS.

1. **Charm v2 watcher.** Move to Bubble Tea 2.0.10, Lip Gloss 2.0.6, Bubbles
   2.2.1, keeping today's behaviour and tests.
2. **Theme engine and project config.** The format, base look, loudness,
   `.agent-stream/` resolution, theme recorded in `header.json`, the Bash
   pane loader, and the space theme end to end. Tests: base byte-identical
   to today; every theme valid; `NO_COLOR` and `TERM=dumb` clean; eggs never
   in the record.
3. **The four product themes.** observatory, blueprint, radio, bottling,
   with their backgrounds, gauges, words, and eggs; preview gallery recorded
   with VHS.
4. **Forge telemetry.** `[metric]` and `[stage]` through all three sides,
   ETA, heartbeat, sparklines, stage timeline.
5. **Combined board.** `agent-stream board` over SSH with the machine column,
   per-run theming, nesting, and "no signal".

## 8.1 Status

- Milestone 1, Charm v2: done.
- Milestone 2, theme engine and project config: done for the pane and the
  watcher, with the space theme end to end.
- Milestone 3, the four product themes: done (observatory, blueprint,
  radio, bottling). The VHS-recorded gallery is not done: VHS is not
  installed in the build environment, so the preview script's theme gallery
  stands in for it.
- Milestone 4, Forge telemetry: done. `[metric]` and `[stage]` pass
  through every adapter as the agent's own lines; the pane styles them;
  `state.json` gains `metrics`, `stages`, `stage`, `progress`, `eta_s`, and
  `counts.metrics`; the watcher's run view gains the telemetry panel. The
  heartbeat is the age of `state.json`, which the tracker rewrites on every
  label line.
- Milestone 5, the combined board: done. `agent-stream board` reads
  `board.json`, polls each machine in the background through one
  `ControlMaster` connection, groups rows under a MACHINE column, draws each
  row's callsign and color from the theme its run recorded, nests children
  under parents (`AGENT_STREAM_PARENT` and `--parent`), shows "no signal"
  with the last answer and the reason, and tails a remote run's
  `display.txt` in the background. Additions to the plan: `"local": true`
  reads a machine's root without ssh, `AGENT_STREAM_SSH` replaces the ssh
  command (the tests use a stand-in), and themes name the MACHINE column
  and the `no_signal` and `dialing` states.

Changes from the plan, as built: the record carries the requested theme in
`state.json` (`theme.name`, `theme.loudness`) rather than in
`header.json`, because `header.json` belongs to the caller and is never
rewritten. Theme glyphs gained `field`, `gauge_open`, and `gauge_close`,
and header words gained `countdown`.

## 9. Non-goals

- No change to what is recorded because of a theme.
- No new runtime dependency for the Bash libraries.
- No daemon or service on the Herdr machines.
- No browser dashboard in this round.

## 10. Resolved questions

The owner asked for the best recommendation on each; these are now part of
the spec.

1. **Nesting does not depend on Herdr.** `agent-stream run` exports
   `AGENT_STREAM_PARENT` (the record directory) to its worker. A nested
   `agent-stream run`, including one started by a skill through
   `herdr agent run`, records it as `parent` in `header.json` and
   `state.json`. If Herdr does not pass the environment through, a skill
   passes `--parent DIR` explicitly. The board nests children under parents
   when both are visible, and shows an orphan as a normal row.
2. **Hosts are named, not discovered.** `board.json` names each machine;
   `ssh` defaults to that name, so a `Host forge` entry in `~/.ssh/config`
   is all a machine needs. `root` defaults to `~/.agent-stream/runs`. A
   machine that does not answer is "no signal", never an error that stops
   the board.
3. **Bottling ships with eggs off.** A theme can declare
   `"eggs_default": false`; a project turns them on with `"eggs": true` in
   `.agent-stream/config.json`. Every other theme keeps eggs on at `loud`.
4. **Forge metrics: the project chooses, with a sensible default.**
   `.agent-stream/config.json` may list `"metrics": ["residual", "rate",
   "cost", "tokens"]`; those get pride of place (gauge, sparkline, magnitude
   readout) in that order. Without the list, the first four metric names a
   run reports are used. Plan progress, ETA, and heartbeat always show and do
   not count toward the four.
