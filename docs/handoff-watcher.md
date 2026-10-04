# Handoff: the watcher TUI (`cmd/agent-stream-watch`)

Status on 2026-10-04: design agreed and committed (`docs/design.md`
section 9.1), module scaffolded, two of five source files written, nothing
built or tested yet. Work was paused on request. This branch holds the work
in progress; `main` holds the finished pane, record, and ACP support.

## What exists on this branch

| File | State |
|---|---|
| `docs/design.md` § 9.1 | Done. The decision, the two views, keys, non-TTY behaviour, what it must never do. |
| `cmd/agent-stream-watch/go.mod` | Done. Module set that resolves together: bubbletea v1.3.10, bubbles v1.0.0, glamour v1.0.0, lipgloss v1.1.1-0.20250404203927 (glamour pins that pseudo-version; `go get glamour@latest` first, then bubbletea and bubbles, then `go mod tidy`). A probe program with these imports built to a 13 MB static binary. |
| `cmd/agent-stream-watch/record.go` | Written, not compiled. `State` mirrors `state.json`; `Run` with `Elapsed`, `Open`, `Label`, `Now`, `OutcomeKind`; `LoadState`, `ScanRoots`, `Refresh` (open runs first, then by mtime), `Tail` (incremental `display.txt` reads with a partial-line buffer, reset if the file shrank). |
| `cmd/agent-stream-watch/render.go` | Written, not compiled. Port of the Bash presenter's semantics to Lip Gloss: cards, plan rows with the `── · plan` divider, waits that carry the word, run and end lines, dim thinking lines, optional Glamour rendering of completed prose paragraphs; `Duration`, `Shorten`, `Count` helpers matching the Bash output. |

## What remains

1. `ui.go`: the Bubble Tea model. Fleet view (table of runs, keys `j`/`k`,
   `enter`, `a` toggle ended, `r`, `q`) and run view (pinned header with
   project, branch, task, agent, model, elapsed, plan `done/total`; a
   `bubbles/viewport` holding the rendered display; pinned footer with the
   current activity or wait and the record path; `p` plan panel, `m`
   markdown toggle, `esc` back). A `tea.Tick` every second calls `Refresh`
   on the roots and `Tail` on the open run; the viewport follows the tail
   while `AtBottom()`.
2. `main.go`: roots from arguments, default `$AGENT_STREAM_HOME/runs`
   (`~/.agent-stream/runs`); when stdout is not a terminal print the fleet
   table once and exit; `--ascii` to force ASCII marks (and auto-detect a
   non-UTF-8 locale or `TERM=dumb`).
3. Tests: `render_test.go` (one protocol line per case, color profile set to
   ASCII so expectations are plain), `record_test.go` (`Refresh` ordering,
   `Tail` across appends and truncation, `Now` for each status).
4. `bin/agent-stream watch [ROOT...]`: exec `agent-stream-watch` from
   `bin/` or `PATH`, else print how to build it:
   `(cd cmd/agent-stream-watch && go build -o ../../bin/agent-stream-watch .)`.
   Add `bin/agent-stream-watch` to `.gitignore`.
5. CI: a third job on `ubuntu-latest` with `actions/setup-go` running
   `go vet ./... && go test ./... && go build ./...` inside
   `cmd/agent-stream-watch`. Leave the Bash jobs as they are.
6. README section "The watcher" and a `tests/agent-watch.test.sh` smoke test
   that runs the binary against a finished record with stdout piped (the
   non-TTY path) when `go` is available, and skips otherwise.
7. Try it in the real multiplexer against `~/.agent-stream/runs` with two
   or three agents running; the fleet view is the point of the exercise.

## Things to know before continuing

- The record is the only interface. The watcher never writes to a run,
  never parses `events.jsonl`, and never replaces the pane. If it needs a
  fact that is not in `state.json`, add it to the protocol and the state
  tracker first (`lib/agent-output.jq`, `lib/agent-state.jq`, both test
  files), then read it here.
- Marks and colors must match the Bash pane so the two views read as one
  system: ✓ ▸ · ~ ✗ ! and cyan, green, amber, red, faint. Lip Gloss honours
  `NO_COLOR` by itself.
- Keep it lightweight: one binary, no daemon, stat-then-read. `Refresh`
  only re-reads a `state.json` whose mtime changed.
- The Bash side has one rule that bit this project already: Bash 3.2
  returns 1 for a `read -t` timeout, the same as EOF. It does not affect Go,
  but it is why the pinned footer's idle tick is Bash 4 only.

## Verification status of what shipped to main

Six Bash test files, `bash -n`, `shellcheck -S error`, the preview in two
modes, and one real Claude run through `bin/agent-stream` all passed on
Linux. The macOS Bash 3.2 job hung on the first push because of the `read
-t` behaviour above; the fix went in before the merge. Not verified: Pi,
Cursor, Grok, Codex, OpenCode streams; any real ACP agent (fake protocol 1
and 2 agents only); the pinned footer in a real multiplexer. The open
questions for the owner are in the pull request body and in
`docs/design.md` section 11.
