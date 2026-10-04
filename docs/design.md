# Design: a pane that explains itself

This note precedes the code. It records the problem, what a communicative
pane shows, the run state model, the record layout, mockups of the pane at
each stage, the options considered, and the decisions with their reasons.
Assumptions that could not be checked are marked **assumption**.

## 1. Problem

Several headless agents (Claude Code, Pi, Cursor, Grok, Codex) run at once,
one per terminal multiplexer pane. Today a pane is a flat scroll of tool
cards and assistant text. A glance does not answer:

- which project and branch the agent is in,
- what it was asked to do,
- what its plan is and how far along it is,
- what it is doing right now and whether it is stuck,
- how it ended and where the record is.

The standard for the result: if a careful engineer narrating their own work
would have said it, the pane shows it. Everything the pane shows must also be
on disk, as plain text, so another program or a `tail -f` follower can read
it while the run is open and after it ends.

## 2. What a communicative pane shows

In the order a colleague would say it:

| Moment | What is said | Source |
|---|---|---|
| Start | "I am claude on claude-sonnet-5-5, in agent-stream on main, in ~/Code/agent-stream. The task is …" | caller (header), detection (git), harness `init` |
| Plan | "My plan is: 1 … 2 … 3 …" | harness todo/plan tool calls |
| Step | "Working on 2 of 3: count its lines" | plan status changes |
| Activity | "Running `wc -l README.md`" / "Reading README.md" | tool calls, Claude `task_summary` |
| Waiting | "Waiting for permission to Write probe-note.txt" / "Retrying in 2 s" / "Compacting context" | harness waits |
| Trouble | "`make test` failed: Error 1" | tool errors, run errors |
| Progress | "3 min in, 2/3 done, 12 tools, 1 error" | counts and timing |
| End | "Done: exit 0 after 4m12s. Summary: … Record: ~/.agent-stream/runs/…" | capture layer, harness result |

Each of these is a state transition, so each must exist in the on-disk state
and in the line protocol before it exists in the terminal styling.

## 3. Evidence: what harnesses actually emit for plans and waits

Captured from real `claude --output-format stream-json --verbose` runs in this
environment (Claude Code 2.1.289, scrubbed; paths and ids replaced):

- The build has **no TodoWrite tool**. `ToolSearch select:TodoWrite` answers
  "No matching deferred tools found". Plans are the deferred **TaskCreate /
  TaskUpdate / TaskList** tools:
  - `tool_use TaskCreate {"subject":"Read the README","description":"…"}` →
    `tool_result` text `Task #1 created successfully: Read the README`,
    `tool_use_result {"task":{"id":"1","subject":"Read the README"}}`.
  - `tool_use TaskUpdate {"taskId":"1","status":"in_progress"}` →
    `tool_use_result {"success":true,"taskId":"1","updatedFields":["status"],
    "statusChange":{"from":"pending","to":"in_progress"}}`.
  - `tool_use TaskList {}` → `tool_use_result {"tasks":[{"id":"1","subject":…,
    "status":"completed","blockedBy":[]},…]}`.
- Older Claude Code builds emit `tool_use TodoWrite {"todos":[{"content":…,
  "status":"pending|in_progress|completed","activeForm":…}]}` with the whole
  list on every call. **Assumption**: taken from the tool's published schema,
  not reproducible here because this build disables the tool.
- Permission requests, when the dispatcher wires `--permission-prompt-tool
  stdio` with `--input-format stream-json`, arrive on stdout as
  `{"type":"control_request","request_id":…,"request":{"subtype":"can_use_tool",
  "tool_name":"Write","input":{…},"description":"<path>","decision_reason":
  "Path is outside allowed working directories","tool_use_id":…}}`. The answer
  travels on stdin, so the stream never shows the release; the next
  `tool_result` does. Without a prompt tool, `-p` mode denies silently: the
  `tool_result` is an error and `result.permission_denials[]` lists
  `{tool_name, tool_use_id, tool_input}`.
- Activity summaries: `{"type":"system","subtype":"task_summary","detail":
  "Listing directory files"}` arrives while a tool runs, and
  `{"type":"system","subtype":"post_turn_summary","status_category":"completed",
  "status_detail":"README.md: 3 lines (wc -l)","needs_action":""}` closes a
  turn. `detail` can be `null`.
- Subagents: nested `assistant`/`user` events carry `parent_tool_use_id`;
  `system` subtypes `task_started {description, subagent_type}`,
  `task_progress {description, last_tool_name, usage}`, `task_updated`,
  `task_notification {status, summary}` frame them. The nested `user` event
  that starts a subagent has a **string** `message.content` (the prompt).
- New top-level event types that currently render as "unhandled":
  `active_goal`, `autocompact_state`. `system` subtypes `thinking_tokens`,
  `task_summary`, `post_turn_summary`, `task_*`.
- `result` carries `terminal_reason`, `stop_reason`, `permission_denials`,
  `num_turns`, `duration_ms`, `total_cost_usd`, `is_error`, `subtype`.

Pi, Cursor, and Grok could not be run here. Their adapters keep the shapes
documented in `lib/agent-output.sh` and gain a **generic plan heuristic**: a
tool whose name contains `todo`, `plan`, or `task` and whose arguments carry a
`todos`, `items`, `tasks`, or `plan` array of objects with a text field
(`content`, `text`, `title`, `subject`, `description`) and an optional
`status`. **Assumption**: none of the three was observed emitting a plan
tool; when the heuristic does not match, the pane shows no plan and says
nothing false.

### 3.1 Agent Client Protocol (ACP), built on protocol 2

Added on request: the pane must work with ACP agents in the owner's final
setup, and the setup is built on protocol 2. The bridge offers protocol 2
by default and the renderer treats the v2 shapes as primary; protocol 1 is
still read because an agent may answer `initialize` with 1. The protocol site is blocked from this environment, so the shapes
come from the published `@agentclientprotocol/sdk` 1.7.0 package on the npm
registry, which ships `schema/schema.json` (protocol 1) and
`schema/v2/schema.unstable.json` (the v2 draft). Both were read in full. No
ACP agent was run here; the bridge and renderer were exercised against fake
agents that speak those shapes.

Framing is the same in both: newline-delimited JSON-RPC 2.0 on the agent's
stdout. `session/update` params carry `sessionId` and `update`, with
`update.sessionUpdate` naming the kind:

| Kind | Protocol | Rendered as |
|---|---|---|
| `agent_message_chunk` / `agent_message` | both / 2 | assistant text. Chunks join. In v2 both carry `messageId`: a whole message whose id already streamed as chunks is not repeated, and any other whole message is shown |
| `agent_thought_chunk` / `agent_thought` | both / 2 | `[think]` then the text, deduplicated by `messageId` the same way |
| `tool_call` / `tool_call_update` | 1 / 2 (v2 has no separate start: the first update for a `toolCallId` is the start) | `[tool] title`, then `[done]`, `[error] title: detail`, or `[error] title: cancelled` by `status` |
| `plan {entries}` / `plan_update {plan: {type: items, entries}}` | 1 / 2 | `[todo]` lines; `plan_removed` clears the plan; markdown and file plans become a `[note]` |
| `state_update {state}` | 2 | `requires_action` is `[wait] input: …`; `idle` with `stopReason` is `[run] result STOP`, plus `(N tokens)` from `usage.totalTokens` |
| `notice {severity, title}` | 2 | `[note]`, `[warn]`, or `[error]` |
| `compaction_update {status}` | 2 | `[wait] compacting context`, then `[note] context compacted` or `[error]` |
| `subagent_update {sessionId, title, state}` | 2 | `[note] subagent STATE: title`; `state` is a StateUpdate object |
| `user_message*`, `available_commands_update`, `current_mode_update`, `config_option_update`, `session_info_update`, `usage_update`, `tool_call_content_chunk`, `terminal_*`, `compaction_summary_chunk`, `session_message*` | both | quiet |

Requests from the agent: `session/request_permission` with `toolCall.title`
(1) or `title` and `subject` (2) and `options[]` of `{optionId, name,
kind}` becomes `[wait] permission: TITLE`. A v2 `subject` is either
`{type: tool_call, toolCall}`, whose title stands in for an empty title, or
`{type: command, command, cwd}`, whose command is shown in parentheses.
Responses carry no method, so the renderer remembers the client's requests
when a dispatcher logs both directions and otherwise recognises
`initialize` by `protocolVersion` (`[note] acp agent NAME VERSION (protocol
N)`), `session/new` by `sessionId` (`[run] acp NAME session ID`), and a
protocol 1 `session/prompt` by `stopReason`. A v2 prompt response carries only
`messageId`; the stop reason arrives in the idle `state_update`.

Grok's `streaming-json` is visibly an ACP mirror (`tool_call` with
`toolCallId`, `title`, `rawInput`, `status`; `tool_call_update`;
`available_commands`), so its adapter also accepts a `plan` event with
`entries`. **Assumption**: not observed.

## 4. Options considered

### 4.1 Scrolling stream or pinned status region

Prototyped both under a pseudo-terminal (`script`), see
`tests/fixtures/agent-present/preview.sh` for the shipped version.

*Pinned region* (DECSTBM scroll region, footer redrawn by a single writer):
works mechanically. Costs: lines that scroll inside a reduced region do not
enter scrollback in several terminals and multiplexers, so the pane loses the
very history a reader scrolls up for; it needs a resize handler, an idle
tick for elapsed time, and a restore on every exit path; and nothing of it
may touch `display.txt`.

*Scrolling stream*: plain append-only text, identical on the terminal and in
`display.txt`, works in every pane, in `tail -f`, and in a file viewer. Costs:
the context is only as close as the last time it was printed.

**Decision**: scrolling stream is the default and the only thing that reaches
`display.txt`. The stream carries a context header at the start, a plan block
whenever the plan changes, a one-line status card every 40 lines (terminal
only, like the existing identity line), and an ending block. The pinned
footer ships as an **opt-in, terminal-only** mode (`AGENT_RUN_STATUS=pinned`)
for people whose terminal keeps scrollback with a scroll region; it draws
only from `state.json` and never writes to any file.

### 4.2 Where structured state comes from

1. A second parser over `events.jsonl` per harness: duplicates every adapter.
2. The renderer writes state itself: jq cannot write files, and splitting its
   stdout breaks the byte-level streaming the presenter depends on.
3. **Chosen**: the renderer's label lines are already a harness-neutral
   protocol. A state tracker consumes those lines as a side branch of the
   display `tee`, holds the state in one jq process, and a tiny Bash loop
   writes `state.json` atomically whenever a snapshot arrives. The same jq
   program rebuilds the final state from `display.txt` alone, so state is
   derived, never a second source of truth.

Consequence: everything the state needs must be a line in the protocol. That
is why the protocol grows `[todo]`, `[step]`, and `[end]`.

### 4.3 Input contract

Callers today write `header.json` with `id, agent, label, cwd, dir,
model_requested, model_source`. **Decision**: keep every field, add optional
`task` (full text), `project`, and `branch`. What the caller does not
supply is detected: `project` from the git top-level directory name (else
the directory name), `branch` from `git rev-parse --abbrev-ref HEAD`, `agent`
from the format, the actual `model` and `session` from the harness `init`
event. The caller's file on disk is not rewritten; the merged view is what
the header shows and what seeds `state.json`. The task falls back to `label`,
then to the first paragraph of `brief.md` if the dispatcher wrote one.

### 4.4 Entry point

The libraries were only usable by sourcing them. **Decision**: add
`bin/agent-stream` with `run`, `follow`, `state`, `render`, and `present`.
`run` wraps a worker: it builds `header.json`, creates the record directory,
calls `run_capture_exec`, writes `exit` and `capture` markers, and prints the
ending. Per-agent default invocations are provided so `agent-stream run
--agent claude --task "…"` is enough; an explicit `-- argv…` always wins. Only
the claude default was verified here; the others are **assumptions** from
each tool's documented flags.

### 4.5 Driving an ACP agent

An ACP agent needs a client on its stdin; capturing its stdout alone shows
nothing because nobody sends `session/prompt`. Options: leave driving to the
dispatcher and only render the logged stream, or ship a minimal client.
**Decision**: both. The renderer works on any logged ACP stream, and
`agent-stream acp-bridge` is a minimal client that wraps the agent as the
worker: it sends `initialize` (offering protocol 2 by default,
`AGENT_STREAM_ACP_VERSION=1` to offer protocol 1, and accepting whatever
the agent answers; the params carry both versions' field names, `info` and
`capabilities` for 2, `clientInfo` and `clientCapabilities` for 1),
`session/new` with the cwd, and `session/prompt` with the task;
answers `session/request_permission` with the first `allow_once` or
`allow_always` option (or a reject option under
`AGENT_STREAM_ACP_PERMISSION=deny`); declines `fs/*`, `terminal/*`, and
elicitation requests with a JSON-RPC error because it declares no such
capabilities; closes the agent's stdin when the turn ends (under protocol
2 the idle `state_update` that carries a stop reason, or any idle after the
turn was seen running, because the schema lets the stop reason be null;
under protocol 1 the prompt response); and
terminates an agent that ignores EOF after a grace period. It relays every
stdout line unchanged, so `events.jsonl` is the agent's raw JSON-RPC and the
`acp-json` renderer sees exactly what the agent said. The dispatcher can keep
its own client and still use the renderer and the state tracker.

### 4.6 Language

Bash 3.2 plus jq stays. The state machine lives in jq, where the renderer's
state machine already lives, so there are still two languages, not three. A
Python rewrite would make the tracker and the presenter simpler, but the
consumer sources these files from a Bash dispatcher on macOS and Linux, and
`python3` is optional in this repository. The one place Bash hurts is the
pinned footer (per-byte loop plus a timer), which is why it is opt-in.

## 5. The activity line protocol (version 2)

One line each, plain text, no terminal controls. Existing lines keep their
exact shape; new ones are additive, so an old presenter prints them as
ordinary text and nothing is lost.

```
[run] AGENT MODEL session ID          start, as emitted today
[run] result SUBTYPE (Nms, N turns)   harness result, as emitted today
[tool] NAME ARGS                      tool start           (unchanged)
[done] NAME                           tool success         (unchanged)
[error] NAME: detail                  tool or run error    (unchanged)
[warn] text   [note] text   [think]   unchanged
[wait] KIND: detail                   permission | retry | compacting | summarizing | retrying
[todo] I/N STATUS text                STATUS in pending | active | done | dropped
[step] text                           the agent's own one-line description of what it is doing
[end] OUTCOME exit N elapsed Ns record PATH   written by the capture layer after the worker exits
[metric] NAME=VALUE [UNIT]            a number from the agent's work, printed by the agent itself
[stage] I/N NAME                      a stage of a long job, printed by the agent itself
```

`[metric]` and `[stage]` come from Forge (docs/spec-themes.md, milestone 4).
No adapter makes them: an agent prints them on lines of its own and every
adapter passes its text through. A malformed `[metric]` is shown as text and
ignored by the state tracker.

Plan lines are self-contained so a tail reader never needs context: `I/N`
positions the item, `N` is the current plan length. The renderer emits the
whole list when a plan first appears or changes length, and only the changed
items otherwise. A wait ends when any later activity line arrives.

## 6. Run state model (`state.json`)

Written atomically (`tmp` then `mv`) on every change while the run is open,
and finalized by the capture layer with the exit status.

```json
{
  "schema": "agent-stream/state/1",
  "id": "20261004-050000-ab12cd34",
  "status": "running",
  "agent": "claude",
  "model": "claude-sonnet-5-5",
  "model_requested": null,
  "session": "1638f3b6",
  "project": {"name": "agent-stream", "dir": "/home/me/Code/agent-stream", "branch": "main"},
  "task": "Rethink and rebuild how this repository shows …",
  "started_at": "2026-10-04T05:00:00Z",
  "updated_at": "2026-10-04T05:03:12Z",
  "ended_at": null,
  "elapsed_s": 192,
  "activity": {"kind": "tool", "text": "Bash pytest -q", "since": "2026-10-04T05:03:10Z"},
  "step": "Running the test suite",
  "waiting": null,
  "todos": [
    {"n": 1, "text": "Read the README", "status": "done"},
    {"n": 2, "text": "Count its lines", "status": "active"},
    {"n": 3, "text": "Report the count", "status": "pending"}
  ],
  "todo_counts": {"total": 3, "done": 1, "active": 1, "pending": 1, "dropped": 0},
  "counts": {"tools": 4, "tool_errors": 1, "errors": 1, "warnings": 0, "waits": 1, "text_lines": 5, "todo_updates": 3},
  "last_text": "README.md has 3 lines.",
  "last_error": "Bash: make: *** [test] Error 1",
  "outcome": null,
  "record": {"dir": "…", "events": "…/events.jsonl", "display": "…/display.txt", "state": "…/state.json"}
}
```

- `status`: `starting` (seeded, no activity yet), `running`, `waiting`,
  `ended`.
- `waiting`: `{"kind","text","since"}` while a `[wait]` is the latest state.
- `outcome` after the end: `{"kind": "success|error|cancelled|unknown",
  "detail": "…", "summary": "…", "exit": 0, "capture": "complete"}`.
  `kind` comes from the exit status and the harness result together; a zero
  exit with an error result is `error`, never `success`.
- Every string is sanitized by the renderer before it reaches this file.

## 7. Record layout

| File | Written by | Contents |
|---|---|---|
| `header.json` | caller or `agent-stream run` | the input contract (section 4.3) |
| `task.txt` | capture | the full task text, when known |
| `events.jsonl` | capture | worker stdout, byte for byte (JSON formats) |
| `stderr.txt` | capture | worker stderr, raw |
| `log.txt` | capture | events then stderr, rebuilt at exit; raw output for `text` |
| `display.txt` | capture | the protocol lines, plain, append-only, including the final `[end]` lines |
| `state.json` | state tracker, finalized by capture | section 6 |
| `events`, `errtee`, `render`, `display-write`, `terminal`, `state` | capture | exit status of each pipeline stage; absence is failure |
| `exit`, `capture` | `agent-stream run` (the dispatcher writes its own today) | worker exit status, capture status |

`display.txt` and `state.json` keep being written when the terminal goes away:
the live sink is the last stage and is followed by a drain, so a closed pane
produces EOF for the presenter, not SIGPIPE for the tee.

## 8. Mockups

Width 60, UTF-8, color described in brackets. The record path is shortened
with `~` as the existing presenter does.

### 8.1 Start

```
────────────────────────────────────────────────────────────
▸ agent-stream · main                              [cyan]
  task    Rethink and rebuild how this repository shows a he…
  agent   claude · requested: default
  cwd     ~/Code/agent-stream
  record  ~/.agent-stream/runs/20261004-050000-ab12cd34/
────────────────────────────────────────────────────────────
│ run claude claude-sonnet-5-5 session 1638f3b6     [dim]
```

### 8.2 Plan appears

```
── · plan 0/3                                      [dim]
│ ▸ 1/3 Read the README                            [cyan mark]
│ · 2/3 Count its lines
│ · 3/3 Report the count
```

### 8.3 Working

```
┌─ · Read README.md
└─ ✓ Read                                          [green]
│ ✓ 1/3 Read the README                            [green]
│ ▸ 2/3 Count its lines
│ now Counting lines with wc                       [dim]

┌─ · Bash wc -l README.md
└─ ✓ Bash
```

### 8.4 Waiting

```
┌─ · Write probe-note.txt
│ ~ waiting: permission Write probe-note.txt       [amber]
│   path is outside allowed working directories
```

With `TERM=dumb`: `| ~ waiting: permission Write probe-note.txt`.

### 8.5 Trouble

```
┌─ · Bash make test
└─ ✗ Bash: make: *** [test] Error 1                [red]
The test target fails; the README is out of date.
```

### 8.6 Status card (terminal only, every 40 lines)

```
── 3m12s · agent-stream main · plan 1/3 · now Bash make test · 12 tools 1 error
```

### 8.7 Ending

```
│ ✓ result success (4210ms, 3 turns)
────────────────────────────────────────────────────────────
✓ done · exit 0 · 4m12s · plan 3/3 done · 12 tools, 1 error   [green]
  summary README.md has 3 lines; TodoWrite unavailable
  record  ~/.agent-stream/runs/20261004-050000-ab12cd34/
────────────────────────────────────────────────────────────
```

Failure: `✗ failed · exit 1 · 0m42s · plan 1/3 done · 3 tools, 2 errors`
in red, followed by the last error line. A worker that exits 0 with an error
result reads `✗ failed · exit 0 but result error_during_execution`.

In `display.txt` the same ending is two plain lines:

```
[run] result success (4210ms, 3 turns)
[end] success exit 0 elapsed 252s record /home/me/.agent-stream/runs/20261004-050000-ab12cd34
```

### 8.8 Pinned footer (opt-in)

```
… scrolling stream above …
────────────────────────────────────────────────────────────
agent-stream main · 3m12s · plan 1/3 · 12 tools 1 error
now Bash make test
```

## 9. Compatibility

Kept working unchanged: `agent_output_render`, `agent_present_stream`,
`agent_present_header`, `agent_present_record`, `agent_present_goal`,
`run_capture_exec`, and the files `events.jsonl`, `display.txt`, `log.txt`,
and the status markers.

Visible changes a dispatcher may notice:

1. `display.txt` gains `[todo]`, `[step]`, `[wait]`, and `[end]` lines. A
   consumer that greps `[run] result` still finds it.
2. Claude events `active_goal`, `autocompact_state`, `task_summary`,
   `post_turn_summary`, `task_*`, and `control_request` no longer print
   "unhandled" notes; the ones that mean something print their meaning.
3. `agent_present_header` prints project, branch, and task lines when they
   are present in the header.
4. `run_capture_exec` writes `state.json`, `task.txt`, and a `state` marker,
   and appends `[end]` lines to `display.txt` after the worker exits.
5. The presenter styles `[wait]` and `[run]` lines instead of passing them
   through as plain text.

None of these require a caller change. Migration for callers that want the
new context: add `task`, `project`, `branch` to `header.json`, or call
`bin/agent-stream run` and let it build the header.

## 9.1 The watcher: a lightweight TUI on the record

Added on request, after the pane shipped. The owner runs several agents at
once and asked whether Charm's stack could "truly elevate" the output. The
decision in section 4.1 stands for the pane itself: a Bash presenter that
writes plain text is what every multiplexer pane, `tail -f`, and the
dispatcher can consume. What Bash cannot do well is the thing a watcher of
many panes wants: one screen that shows every run's project, step, plan
progress, and waiting state, and a scrollable view of any run with the
context pinned and real scrollback. That is a job for a TUI runtime.

**Decision**: `cmd/agent-stream-watch`, a single static Go binary built on
Bubble Tea (event loop), Bubbles (viewport), Lip Gloss (styles), and
Glamour (markdown for completed answers). It is optional: the libraries,
the pane, and the record are unchanged, and `agent-stream watch` falls back
to a clear message when the binary is not built. The binary reads only the
record files, so it is lightweight by construction: no daemon, no socket,
no event parsing. Each second it stats the run directories, re-reads the
`state.json` files that changed, and tails `display.txt` of the open run
from the last offset.

Two views:

- **Fleet**: one row per run under the record roots (default
  `$AGENT_STREAM_HOME/runs`, more roots as arguments), open runs first,
  then the most recently ended. Columns: state mark, project and branch,
  agent and model, plan `done/total`, what it is doing or waiting for,
  elapsed, outcome. Keys: `j`/`k` or arrows move, `enter` opens, `a`
  toggles ended runs, `r` refreshes now, `q` quits.
- **Run**: a pinned header (project, branch, task shortened, agent, model,
  elapsed, plan progress), the display rendered with the same marks and
  semantics as the Bash presenter (cards, plan rows, waits, ending), a
  pinned footer with the current activity or wait and the record path.
  The viewport follows the tail while it is at the bottom and stops
  following when the reader scrolls up. `p` toggles a plan panel, `m`
  toggles Glamour rendering of completed prose paragraphs, `esc` returns to
  the fleet.

When stdout is not a terminal the binary prints the fleet table once and
exits, so the same command works in scripts and in a pane that is not
interactive. Colors are adaptive to light and dark terminals and honour
`NO_COLOR`.

What it does not do, on purpose: it never writes to a record, never drives
an agent, and never replaces the pane. The pane remains the record of what
the agent did; the watcher is a window onto several records at once.

As built, a few details settled differently from the plan above:

- The fleet shows every open run and the ten most recent ended runs; `a`
  shows all ended runs. A long history would otherwise push the open runs'
  neighbours off the screen.
- An open run whose `state.json` has not changed for two minutes reads
  `quiet 4m10s · …`. That answers "is it stuck" without guessing: the
  state tracker writes on every label line and at most once a second for
  text, so a quiet record means a quiet agent or a dead one.
- "Now" prefers the agent's own step line, then the tool running at that
  moment, then the active plan item, which the plan column and panel
  already show.
- Markdown mode holds prose until the next label line, so a list or a
  fenced block with blank lines renders as one block, and shows the held
  prose rendered while it streams. The unfinished last line of the record
  is always shown as it is.
- The Glamour style is chosen once before the event loop starts, because
  asking the terminal for its background while Bubble Tea reads keys races
  with the input.
- `AGENT_STREAM_WATCH` names the binary `agent-stream watch` runs, so the
  smoke test and CI can point at a fresh build.

## 9.2 Charm v2 (milestone 1 of docs/spec-themes.md)

The watcher moved to Bubble Tea 2.0.10, Bubbles 2.2.1, Lip Gloss 2.0.6, and
Glamour 2.0.1, under the new `charm.land` import paths, and needs Go 1.26.
What changed and why it matters:

- `View()` returns a `tea.View`; the alternate screen and window title are
  set on the view, not as program options.
- Keys arrive as `tea.KeyPressMsg`; the space bar is `"space"`.
- Lip Gloss v2 has no global color profile. Styles always render full color
  and the output downsamples: Bubble Tea through `tea.WithColorProfile`, the
  printed table through a `colorprofile.Writer`. `colorProfile` in `main.go`
  keeps the pane's rules (`NO_COLOR`, `TERM=dumb`, `AGENT_RUN_COLOR`, pipes).
  This is what lets themes carry true-color, 256-color, and 16-color values
  side by side.
- `termenv` is gone from the watcher's dependencies.

Behaviour is unchanged: the same tests pass, comparing the text a reader sees
(`ansi.Strip`), plus a new test that the printed table carries no escape bytes
on a pipe or under `NO_COLOR`, and only 16-color codes under
`AGENT_RUN_COLOR=always`.

## 10. What was verified, and how

Second round (ACP protocol 2 and the watcher):

- The v2 renderer was checked again against the SDK 1.7.0 schema, and three
  mismatches were fixed: the permission `subject`, the subagent `state`
  object, and the idle `usage` object. Running the bridge against a
  synthetic protocol 2 agent found a fourth: a whole `agent_message` was
  dropped whenever an earlier message had streamed as chunks, so the final
  answer of a v2 turn could vanish. Messages and thoughts are now
  deduplicated by `messageId`, with a regression test for each.
- Seven Bash test files, `bash -n`, and `shellcheck -S error` pass on Linux.
  `gofmt`, `go vet`, and `go test` pass for the watcher; the tests drive the
  Bubble Tea model with window, key, and tick messages and assert that every
  view fits the terminal.
- The watcher was run in tmux against records from the bridge: a finished
  run, a failed run, and a run held open mid-tool. Fleet, run view,
  following and scrolling, the plan panel, markdown, and ASCII at 72
  columns all rendered as intended.

Not verified in the second round: a real ACP agent (none could be run
here; the shapes are the schema's), the watcher in a real multiplexer with
several live agents, and the Go build on macOS.

First round:

- `for t in tests/*.test.sh; do bash "$t"; done`: six test files, all
  passing on Linux with Bash 5.2 and jq 1.7. `bash -n` and `shellcheck -S
  error` over `lib/`, `bin/`, `tests/`. The preview script renders with
  `AGENT_RUN_COLOR=never` and with `TERM=dumb`.
- A real `claude -p … --output-format stream-json --verbose` run through
  `bin/agent-stream run`: the plan from TaskCreate / TaskUpdate, a denied
  shell redirection, the agent's own summary, and the ending card all
  appeared; the record held every file with every marker at 0; the
  `state.json` matched the pane. Its output is in the README and the pull
  request.
- Real captures (not committed) of TaskCreate / TaskUpdate / TaskList, a
  stdio `control_request` permission prompt, a subagent run, and the
  `task_summary` / `post_turn_summary` events; the fixtures in the tests are
  scrubbed copies of those shapes.
- The pinned footer under a pseudo-terminal (`script`): the scroll region is
  set, the footer redraws, and the region is restored on exit.

Not verified here: Bash 3.2 itself (no binary could be fetched; CI covers
it on macOS), Pi, Cursor, Grok, Codex, and OpenCode streams, any real ACP
agent, and the pinned footer in a real multiplexer.

## 11. Open questions for the owner

- Should the dispatcher adopt `bin/agent-stream run` or keep calling
  `run_capture_exec` with its own header?
- Is `~/.agent-stream/runs` the right default record root for the entry
  point, or should it follow the dispatcher's root?
- Is a pinned footer worth keeping once tried in the real multiplexer, or
  should it be removed in favour of the status card alone?
- Should the periodic status card also be written to `display.txt`? It was
  kept terminal-only so the file stays a faithful log of the agent's own
  activity.
- ACP: does the final setup drive agents itself (then only `acp-json` and
  the state tracker matter) or should `acp-bridge` be the client? The
  bridge now offers protocol 2; should the default permission policy stay
  `allow`?
- Watcher: is ten the right number of ended runs to show by default, and is
  two minutes the right threshold for calling an open run quiet?
