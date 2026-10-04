# agent-stream

Bash libraries that turn a coding agent's event stream into readable live output in a terminal pane, and save the raw events next to a plain-text copy of what was shown.

They were written to watch headless agents (Claude Code, Pi, Cursor, Grok, Codex, OpenCode) work inside [Herdr](https://herdr.dev) panes. Nothing here depends on Herdr: the output is ordinary text on stdout, so any terminal or multiplexer pane works.

A Claude Code run that reads a file, fails a command, and answers looks like this in the pane:

```
[run] claude claude-opus-5-5 session 3f9c2a71
I will read the README first.

┌─ · Read README.md
└─ ✓ Read

┌─ · Bash make test
└─ ✗ Bash: make: *** [test] Error 1
The test target fails; the README is out of date.
[run] result success (4210ms, 3 turns)
```

## How it works

The stream passes through three stages, one library each.

| Stage | File | Function | Does |
|---|---|---|---|
| Render | `lib/agent-output.sh`, `lib/agent-output.jq` | `agent_output_render FORMAT` | Reads harness events on stdin and writes plain activity lines: assistant text as it arrives, plus `[tool]`, `[done]`, `[error]`, `[warn]`, `[note]`, `[think]`, `[wait]`, and `[run]` label lines. Tool payloads are never dumped. |
| Present | `lib/agent-present.sh` | `agent_present_stream` | Reads those lines and styles them for a terminal: tool cards, side-bordered notes, color when the terminal supports it. |
| Capture | `lib/run-capture.sh` | `run_capture_exec FORMAT -- argv...` | Runs the worker, saves its raw output into a record directory, and feeds the other two stages. |

`FORMAT` names the harness protocol.

| Format | Harness invocation it expects |
|---|---|
| `claude-json` | `claude --output-format stream-json --verbose` |
| `pi-json` | `pi --mode json` |
| `cursor-json` | `cursor-agent --output-format stream-json --stream-partial-output` |
| `grok-json` | `grok --output-format streaming-json` |
| `text` | Any worker that prints plain text, such as Codex or OpenCode |

The event shapes each adapter handles are documented at the top of `lib/agent-output.sh`.

## Requirements

Bash 3.2 or newer and `jq`. The libraries are Bash-only; source them from Bash, not zsh. `python3` is optional and is used only to drop a repeated final answer from `text` workers.

## Use

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
| `events.jsonl` | The worker's stdout, byte for byte (JSON formats) |
| `stderr.txt` | The worker's stderr (JSON formats) |
| `log.txt` | Events followed by stderr, rebuilt after the worker exits. For `text`, the raw combined output |
| `display.txt` | The rendered plain-text activity, free of terminal controls. A second terminal can follow a run by tailing this file |
| `events`, `errtee`, `render`, `display-write`, `terminal` | Exit status of each pipeline stage. A missing marker counts as a failure |

If `$run/header.json` exists, `run_capture_exec` prints it as a run header first; see `agent_present_header` for the fields.

## Environment

| Variable | Effect |
|---|---|
| `AGENT_RUN_COLOR` | `always`, `never`, or `auto` (default: color only on a terminal) |
| `NO_COLOR` | Disables color, even over `AGENT_RUN_COLOR=always` |
| `TERM=dumb`, non-UTF-8 locale | ASCII marks and borders instead of Unicode |
| `COLUMNS` | Width of horizontal rules, clamped to 40 through 120 |
| `AGENT_RUN_RUN` | When set, the pane repeats an `agent-run <id> streaming <path>` identity line every 40 lines |

## Where the names come from

These libraries were extracted from a private setup repository, where a dispatcher called `agent-run` sources them. That is why variables are named `AGENT_RUN_*` and some messages mention `agent-run --follow`. `agent_present_record` and `agent_present_goal` render that dispatcher's run and goal records; they are included because they share the presentation code, and `tests/fixtures/agent-present/preview.sh` shows the JSON they accept.

## Test

```bash
for t in tests/*.test.sh; do bash "$t"; done
tests/fixtures/agent-present/preview.sh   # eyeball every presenter in a real terminal
```

CI runs the tests, `bash -n`, and `shellcheck -S error` on Linux and on macOS with the system Bash 3.2.

## License

Apache-2.0. See `LICENSE`.
