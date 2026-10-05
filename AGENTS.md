# agent-stream

Bash libraries and one command that render, style, track, and capture coding-agent output. `README.md` describes the stages and the record files; `docs/design.md` records the decisions; `docs/spec-themes.md` is the spec for themes, Forge telemetry, and the board; `docs/handoff.md` says where things stand and what is not verified yet. The quick nav at the end maps the tree.

- Keep every library Bash 3.2 compatible: no `mapfile`, associative arrays, `${var,,}`, or fractional `read -t`, and never tell a `read -t` timeout from EOF by its status (3.2 returns 1 for both; the status above 128 is Bash 4). macOS runs the tests on `/bin/bash` 3.2.
- Runtime dependencies are `bash` and `jq`. `python3` and `git` stay optional. Do not add another. The watcher in `cmd/agent-stream-watch` is an optional Go binary on Charm v2 (`charm.land/bubbletea/v2`, `bubbles/v2`, `lipgloss/v2`, `glamour/v2`; Go 1.26). Lip Gloss v2 renders full color and the output downsamples it, so color decisions live in `colorProfile` in `main.go`, and Go tests compare text with `ansi.Strip`; nothing in `lib/` or `bin/agent-stream` may depend on it.
- The watcher reads `state.json` and `display.txt` only; the board (`--board`) reads the same two files over SSH and writes nothing on any machine. It never writes to a record, never parses `events.jsonl`, and never drives an agent. If it needs a fact, add it to the protocol and the state tracker first.
- ACP work targets protocol 2: the bridge offers it by default and still accepts an agent that answers 1. Check shapes against the published `@agentclientprotocol/sdk` schema, not memory.
- The activity line protocol (`[run]`, `[tool]`, `[done]`, `[error]`, `[warn]`, `[note]`, `[think]`, `[wait]`, `[todo]`, `[step]`, `[end]`, and Forge's `[metric]` and `[stage]`, which agents print in their own text) is the contract between `agent_output_render`, `agent_present_stream`, and `agent_state_track`. Change all three sides and their test files together, and keep every line self-contained so a `tail -f` reader needs no context.
- Themes (`themes/*.json`, `lib/agent-theme.sh`, `cmd/agent-stream-watch/theme.go`) are presentation only. The base look must stay byte-identical to the pre-theme output, and it is what a pipe, `NO_COLOR`, `TERM=dumb`, a non-UTF-8 locale, or loudness `quiet` get. A theme never changes `display.txt` or `state.json`, every themed state keeps its mark and plain word, theme glyphs are single-width, and Bash and Go must agree on callsigns (shared golden table in both test suites). New egg triggers go in code with a test; themes only supply their text.
- `display.txt` is plain append-only text. Anything that redraws (the status card, the pinned footer) is terminal-only and lives in `lib/agent-present.sh`.
- `state.json` is derived from `display.txt` lines, never from events. If a fact belongs in the state, it belongs in the protocol first.
- Never print a tool payload, a thinking signature, or an unsanitized terminal control sequence. The tests assert each one.
- Add an adapter by reading the harness's real event stream first. Record the evidence in the header comment of `lib/agent-output.sh`, add fixture events to `tests/agent-output.test.sh`, and say in the comment which shapes were observed and which are assumptions.
- Verify with `for t in tests/*.test.sh; do bash "$t"; done`, then `bash -n` and `shellcheck -S error` on every file in `lib/`, `bin/`, and `tests/`. Run the tests under `/bin/bash` on macOS as well. For the watcher, run `gofmt -l`, `go vet ./...`, and `go test ./...` in `cmd/agent-stream-watch`, then `AGENT_STREAM_WATCH=<built binary> bash tests/agent-watch.test.sh`; with `sshd` installed, add `AGENT_STREAM_REAL_SSH=1` to run the board over a private loopback sshd, as CI does on Linux and macOS.
- This repository is public. Do not commit hostnames, addresses, home paths, credentials, or agent transcripts. Fixtures must be synthetic or scrubbed.

## Quick nav

The pipeline: worker stdout → render (events to activity lines) → `display.txt` → present (the pane) and track (`state.json`). The watcher and the board read the record afterwards.

| Path | What it is |
|---|---|
| `bin/agent-stream` | The command: `run`, `follow`, `state`, `render`, `present`, `watch`, `board`, `acp-bridge` (the ACP client) |
| `lib/agent-output.sh`, `.jq` | Render: harness events to activity lines, one adapter per format (`claude-json`, `pi-json`, `cursor-json`, `grok-json`, `acp-json`, `text`). The header comment holds the evidence for each adapter |
| `lib/agent-present.sh` | Present: the pane, with the header card, plan rows, waits, the status card, the ending, and the pinned footer |
| `lib/agent-theme.sh`, `.jq` | The pane's theme loader: theme JSON to shell variables, callsigns, gauges, background bands, eggs |
| `lib/agent-state.sh`, `.jq` | Track: activity lines to `state.json`, including plan, waits, counts, outcome, metrics, stages, ETA |
| `lib/run-capture.sh` | Capture: FIFOs and tee, the record files, the context (git project and branch), the theme choice, the `[end]` line |
| `cmd/agent-stream-watch/` | The optional Go watcher (Charm v2). `main.go` flags and color, `record.go` state and tail, `render.go` lines, `ui.go` fleet and run views, `theme.go` and `eggs.go` themes, `telemetry.go` the Forge panel, `board.go` the SSH board |
| `themes/*.json`, `themes/README.md` | The five design files (space, observatory, blueprint, radio, bottling) and the format |
| `tests/*.test.sh` | One Bash suite per library, plus the entry point, ACP, and the watcher smoke test. `tests/fixtures/agent-present/preview.sh` shows every state and theme |
| `.github/workflows/check.yml` | CI: the Bash suite on Ubuntu and macOS Bash 3.2, the watcher on Ubuntu and macOS with real sshd |

| To change… | Touch, together |
|---|---|
| A protocol line | `agent-output.jq`, `agent-present.sh`, `agent-state.jq`, `render.go`, their tests, and the protocol lists in `README.md`, `docs/design.md` section 5, and this file |
| A harness adapter | `agent-output.jq`, the evidence comment in `agent-output.sh`, fixtures in `tests/agent-output.test.sh` |
| A `state.json` field | `agent-state.jq`, `State` in `record.go`, `tests/agent-state.test.sh`, `docs/design.md` section 6 |
| A theme word, glyph, or egg | the theme JSON, the base in `agent-theme.sh` and `theme.go`, `themes/README.md`, both theme test suites |
| The watcher or the board | `cmd/agent-stream-watch/` and its Go tests, `tests/agent-watch.test.sh`, the watcher usage text in `main.go`, `README.md` |
