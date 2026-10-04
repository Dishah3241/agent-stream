# agent-stream

Bash libraries and one command that show a headless coding agent at work in a terminal pane the way a careful colleague would narrate it: who is working where, on what task, with what plan, on which step, waiting for what, and how it ended. Every run leaves a complete record on disk: the raw events byte for byte, stderr, the plain-text display, and a structured `state.json` another program can read while the run is open.

They were written to watch headless agents (Claude Code, Pi, Cursor, Grok, Codex, OpenCode, and any Agent Client Protocol agent) work inside [Herdr](https://herdr.dev) panes. Nothing here depends on Herdr: the output is ordinary text on stdout, so any terminal or multiplexer pane works.

A real Claude Code run through `bin/agent-stream` looks like this (paths shortened):

```
────────────────────────────────────────────────────────────────────────────────
▸ realproj · main
  task    Plan this with TaskCreate/TaskUpdate: 1) read README.md and calc.py, 2) add…
  run     real1 · claude
  model   requested: none — claude default
  cwd     ~/Code/realproj
  output  ~/.agent-stream/runs/real1/
────────────────────────────────────────────────────────────────────────────────
│ run claude claude-sonnet-5-5 session 1638f3b6

── · plan
│ · 1/1 Read README.md and calc.py
│ · 2/2 Add and run tests.py
│ · 3/3 Append tests.py line to README.md
│ ▸ 1/3 Read README.md and calc.py

┌─ · Read README.md
└─ ✓ Read

── · plan
│ ✓ 1/3 Read README.md and calc.py
│ ▸ 2/3 Add and run tests.py

┌─ · Bash python3 tests.py
└─ ✓ Bash
Tests pass; now appending the README line.

┌─ · Bash printf '\n`tests.py` runs plain-assert tests for `add` and `sub`...
└─ ✗ Bash: Output redirection to 'README.md' needs approval. The path is ins...
Shell redirection needs approval, so I'll use the Edit tool instead.

── · plan
│ ✓ 3/3 Append tests.py line to README.md
│ summary: tests.py written & green; README appended
│ ✓ result success (16620ms, 17 turns, 1 denied)
────────────────────────────────────────────────────────────────────────────────
✓ done · exit 0 · 18s · plan 3/3 done · 7 tools, 1 error
  summary tests.py written & green; README appended
  record  ~/.agent-stream/runs/real1/
────────────────────────────────────────────────────────────────────────────────
```

`docs/design.md` records the problem, the evidence, the options considered, and the decisions.

## How it works

The stream passes through three stages plus one side branch, one library each.

| Stage | File | Function | Does |
|---|---|---|---|
| Render | `lib/agent-output.sh`, `lib/agent-output.jq` | `agent_output_render FORMAT` | Reads harness events on stdin and writes the activity line protocol: assistant text as it arrives, plus `[run]`, `[tool]`, `[done]`, `[error]`, `[warn]`, `[note]`, `[think]`, `[wait]`, `[todo]`, and `[step]` lines. Tool payloads are never dumped. |
| Present | `lib/agent-present.sh` | `agent_present_stream`, `agent_present_header`, `agent_present_end` | Styles those lines for a terminal: a context header, tool cards, plan rows, waits, a status card every 40 lines, and the ending card. Color when the terminal supports it, never color alone. |
| Track | `lib/agent-state.sh`, `lib/agent-state.jq` | `agent_state_track RECORD_DIR` | Reads the same lines as a side branch and keeps `state.json` current: project, task, plan, activity, waits, counts, timing, outcome. |
| Capture | `lib/run-capture.sh` | `run_capture_exec FORMAT -- argv...` | Runs the worker, saves its raw output, feeds the other stages, finalizes the state with the exit status, and prints the ending. |

`FORMAT` names the harness protocol.

| Format | Harness invocation it expects |
|---|---|
| `claude-json` | `claude --output-format stream-json --verbose` |
| `pi-json` | `pi --mode json` |
| `cursor-json` | `cursor-agent --output-format stream-json --stream-partial-output` |
| `grok-json` | `grok --output-format streaming-json` |
| `acp-json` | Any Agent Client Protocol agent's stdout (newline-delimited JSON-RPC, protocol 1 and the v2 schema); `bin/agent-stream` drives one for you |
| `text` | Any worker that prints plain text, such as Codex or OpenCode |

The event shapes each adapter handles, and which ones were observed in real streams, are documented at the top of `lib/agent-output.sh`.

## The activity line protocol

Plain text, one line each, identical on the terminal and in `display.txt`. Old presenters print the new lines as ordinary text.

```
[run] AGENT MODEL session ID                 start
[run] result SUBTYPE (Nms, N turns[, N denied])  harness result
[tool] NAME ARGS   [done] NAME   [error] NAME: detail
[warn] text   [note] text   [think]
[wait] KIND: detail                           permission | retry | compacting | input
[todo] I/N STATUS text                        STATUS in pending | active | done | dropped
[step] text                                   the agent's own one-line "what I am doing"
[end] OUTCOME exit N elapsed Ns record PATH   appended by the capture layer after the worker exits
```

Plan lines are self-contained: `I/N` positions the item and `N` is the plan length, so a `tail -f` reader never needs context. The whole list is shown when a plan appears or changes length; afterwards only changed items.

## Requirements

Bash 3.2 or newer and `jq`. The libraries are Bash-only; source them from Bash, not zsh. `python3` is optional and is used only to drop a repeated final answer from `text` workers. `git` is used, when present, to detect the project and branch.

## Use

### The command

```bash
bin/agent-stream run --agent claude --task "summarize this repo"
bin/agent-stream run --agent acp --task "fix the tests" -- claude-code-acp
bin/agent-stream run --format pi-json --task "…" -- pi --mode json -p "…"
bin/agent-stream follow ~/.agent-stream/runs/<id>     # replay, or tail while open
bin/agent-stream state  ~/.agent-stream/runs/<id>     # print state.json (--rebuild from display.txt)
```

`run` builds `header.json` (task in full, project and branch detected from git, agent, model requested), creates the record under `$AGENT_STREAM_HOME/runs/<id>` (default `~/.agent-stream`), runs the worker through the capture layer, writes the `exit` and `capture` markers, prints the ending card, and exits with the worker's status. `--agent` picks the format and a default worker command; a command after `--` always wins. Only the `claude` default was verified against a real run; see `agent-stream help`.

`--agent acp` runs the agent through the built-in ACP client (`agent-stream acp-bridge`): it sends `initialize`, `session/new`, and `session/prompt`, answers `session/request_permission` (allow by default; `AGENT_STREAM_ACP_PERMISSION=deny` picks a reject option), declines file-system and terminal requests, and closes the agent's stdin when the turn ends (the prompt response under protocol 1, the idle `state_update` under protocol 2; `AGENT_STREAM_ACP_VERSION` sets the version offered). The agent's raw JSON-RPC output is what lands in `events.jsonl`.

### The libraries

To style a stream you already have, pipe it through the first two stages:

```bash
. lib/agent-output.sh
. lib/agent-present.sh
claude -p "summarize this repo" --output-format stream-json --verbose \
  | agent_output_render claude-json \
  | agent_present_stream
```

To run a worker and keep a record, set `run` to an existing record directory and `lib` to this repository's `lib` directory, then call `run_capture_exec`. Call it with `errexit` off, because it reads the worker's exit status:

```bash
set +e
run="$(mktemp -d)"
lib="$PWD/lib"
. "$lib/run-capture.sh"
run_capture_exec claude-json -- claude -p "summarize this repo" --output-format stream-json --verbose
echo "worker exit: $status, capture: $capture"
```

`run_capture_exec` sets `status` to the worker's exit status and `capture` to `0` when the raw output was saved completely. The record directory then holds:

| File | Contents |
|---|---|
| `header.json` | The caller's input contract, when the caller wrote one (see below) |
| `task.txt` | The full task text, when known |
| `events.jsonl` | The worker's stdout, byte for byte (JSON formats) |
| `stderr.txt` | The worker's stderr (JSON formats) |
| `log.txt` | Events followed by stderr, rebuilt after the worker exits. For `text`, the raw combined output |
| `display.txt` | The activity lines, plain, append-only, ending with one `[end]` line. A second terminal can follow a run by tailing this file |
| `state.json` | Structured run state (next section), rewritten atomically on every change and finalized with the exit status |
| `events`, `errtee`, `render`, `display-write`, `terminal`, `state` | Exit status of each pipeline stage. A missing marker counts as a failure |
| `exit`, `capture` | Written by `bin/agent-stream run` |

The record stays complete when the pane goes away: the live sink is the last stage and is followed by a drain, the display tee ignores SIGPIPE, and the state tracker drains its own input if jq ever dies.

### The input contract (`header.json`)

If `$run/header.json` exists, `run_capture_exec` prints it as the context header and seeds the state from it. Fields: `id`, `agent`, `label`, `cwd`, `dir`, `model_requested`, `model_source` as before, plus optional `task` (full text), `project`, and `branch`. What the caller leaves out is detected: `project` from the git top-level directory name (else the directory name), `branch` from git, `agent` from the format, `id` from the record directory name, `task` from `label`, then from `brief.md`. The actual model and session come from the stream. The file on disk is never rewritten.

### `state.json`

```json
{
  "schema": "agent-stream/state/1",
  "id": "real1", "status": "ended",
  "agent": "claude", "model": "claude-sonnet-5-5", "model_requested": null, "session": "1638f3b6",
  "project": {"name": "realproj", "dir": "/…/realproj", "branch": "main"},
  "task": "Plan this with TaskCreate/TaskUpdate …",
  "started_at": "2026-10-04T05:52:40Z", "updated_at": "…", "ended_at": "…", "elapsed_s": 18,
  "activity": {"kind": "done", "text": "result success", "since": "…"},
  "step": null,
  "waiting": null,
  "todos": [{"n": 1, "text": "Read README.md and calc.py", "status": "done"}, …],
  "todo_counts": {"total": 3, "done": 3, "active": 0, "pending": 0, "dropped": 0},
  "counts": {"tools": 7, "tool_errors": 1, "errors": 1, "warnings": 0, "notes": 0, "waits": 0, "text_lines": 3, "todo_updates": 9, "turns": 17},
  "last_text": "I added `tests.py` …", "last_error": "Bash: Output redirection to … needs approval…", "last_warning": null,
  "result": {"subtype": "success", "detail": "success (16620ms, 17 turns, 1 denied)", "kind": "success"},
  "outcome": {"kind": "success", "exit": 0, "capture": "complete", "summary": "tests.py written & green; README appended", "detail": "…"},
  "record": {"dir": "…", "events": "…/events.jsonl", "display": "…/display.txt", "state": "…/state.json", "log": "…/log.txt"}
}
```

`status` is `starting`, `running`, `waiting`, or `ended`. `waiting` holds `{kind, text, since}` while a `[wait]` is the latest state; any later activity clears it. `outcome.kind` is `success`, `failed` (nonzero exit), `error` (zero exit but an error result), `cancelled`, or `exited` (zero exit, no harness result). The state is derived from `display.txt`, so `agent-stream state DIR --rebuild` reproduces it.

## Environment

| Variable | Effect |
|---|---|
| `AGENT_RUN_COLOR` | `always`, `never`, or `auto` (default: color only on a terminal) |
| `NO_COLOR` | Disables color, even over `AGENT_RUN_COLOR=always` |
| `TERM=dumb`, non-UTF-8 locale | ASCII marks and borders instead of Unicode |
| `COLUMNS` | Width of horizontal rules and the shortened task, clamped to 40 through 120 |
| `AGENT_RUN_RUN` | When set, the pane repeats an `agent-run <id> streaming <path>` identity line every 40 lines |
| `run` | When set to a record directory, the pane prints a status card from its `state.json` every 40 lines |
| `AGENT_RUN_STATUS=pinned` | Terminal-only, opt-in: a two-line footer pinned below the scrolling stream, redrawn from `state.json` at most once a second. Lines scrolled inside the reduced region may not reach scrollback in some terminals |
| `AGENT_STREAM_HOME` | Record root for `bin/agent-stream` (default `~/.agent-stream`) |
| `AGENT_STREAM_ACP_PERMISSION`, `AGENT_STREAM_ACP_VERSION`, `AGENT_STREAM_ACP_GRACE` | ACP bridge policy: `allow` (default) or `deny`; protocol version offered (default 1); seconds to wait for the agent to exit (default 10) |

## Where the names come from

These libraries were extracted from a private setup repository, where a dispatcher called `agent-run` sources them. That is why variables are named `AGENT_RUN_*` and some messages mention `agent-run --follow`. `agent_present_record` and `agent_present_goal` render that dispatcher's run and goal records; they are included because they share the presentation code, and `tests/fixtures/agent-present/preview.sh` shows the JSON they accept.

## Test

```bash
for t in tests/*.test.sh; do bash "$t"; done
tests/fixtures/agent-present/preview.sh   # eyeball every state in a real terminal
```

CI runs the tests, `bash -n`, the preview without a terminal, and `shellcheck -S error` on Linux and on macOS with the system Bash 3.2.

## License

Apache-2.0. See `LICENSE`.
