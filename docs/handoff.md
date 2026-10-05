# Handoff

State of the repository on 2026-10-05, for whoever picks it up next, human
or agent. `AGENTS.md` has the rules and a map of the tree; this file says
where things stand and what to do next.

## Where things stand

Everything is on `main`. There are no open pull requests.

| Pull request | What it brought |
|---|---|
| #1 | The pane that explains itself: the activity line protocol v2, `state.json`, `bin/agent-stream`, the capture layer, ACP support |
| #2 | The watcher on Charm v2, ACP on protocol 2, project themes, Forge telemetry, the combined board, and run nesting |

`docs/spec-themes.md` is the spec for #2. All five of its milestones are
built: Charm v2, the theme engine, the five themes, Forge telemetry, and the
combined board. Section 8.1 of the spec says how each one landed.

CI is green on `main`: the Bash suite on Ubuntu and on macOS with the system
Bash 3.2, and the watcher on Ubuntu and macOS, including the board over a
real `sshd`.

## What each product gets

| Product | Theme | What it adds |
|---|---|---|
| agent-stream, unconfigured projects | `space` | star names for callsigns, a rocket on the plan gauge, book sci-fi easter eggs |
| Forge | `observatory` | `[metric]` and `[stage]` telemetry: sparklines, a forecast, a heartbeat, a stage timeline |
| Miini | `blueprint` | a graph-paper backdrop, a dimension-line gauge |
| Air | `radio` | VU meters, notes on a staff |
| PC | `bottling` | a production line, a filling bottle, eggs off by default |

A project chooses its theme in `.agent-stream/config.json` at its git top
level (`themes/README.md` has the format). The board, `agent-stream board`,
reads `~/.config/agent-stream/board.json` and shows every machine's runs
together.

## Verify before you change anything

```bash
for t in tests/*.test.sh; do bash "$t"; done
bash -n lib/*.sh bin/agent-stream tests/*.sh   # and shellcheck -S error on the same
cd cmd/agent-stream-watch && gofmt -l . && go vet ./... && go test -race ./...
go build -o /tmp/asw . && cd ../..
AGENT_STREAM_REAL_SSH=1 AGENT_STREAM_WATCH=/tmp/asw bash tests/agent-watch.test.sh
```

`AGENT_STREAM_REAL_SSH=1` needs `sshd`. Without it the test skips that part.
The watcher needs Go 1.26 or newer; the Bash side needs only `bash` and `jq`.

## Not verified yet

These need the owner's machines or accounts. Nothing in the build
environment could reach them.

1. **The board across the real Herdr machines.** It is tested over real
   ssh, against a private `sshd` on one host, on Linux and macOS. It has
   not read a remote machine. Each machine needs batch-mode (passwordless)
   ssh from the board's host and a `Host` entry whose name matches
   `board.json`.
2. **Nesting through `herdr agent run`.** `agent-stream run` exports
   `AGENT_STREAM_PARENT` to its worker. If Herdr does not pass the
   environment through to the agent it starts, the skills must pass
   `--parent "$AGENT_STREAM_PARENT"` to the nested `agent-stream run`.
   Check once, on a real skill.
3. **A real ACP agent.** The bridge and renderer are checked against the
   `@agentclientprotocol/sdk` 1.7.0 schemas and fake protocol 1 and 2
   agents.
4. **The watcher inside a real Herdr pane**, and the pinned footer
   (`AGENT_RUN_STATUS=pinned`) in a real multiplexer.
5. **Pi, Cursor, Grok, Codex, and OpenCode streams** against real runs.
   Only Claude Code was captured live. The others follow the shapes noted
   in the header of `lib/agent-output.sh`.
6. **The VHS-recorded theme gallery.** VHS was not installed. Until it is,
   `tests/fixtures/agent-present/preview.sh` shows every theme in a
   terminal.

## Open questions for the owner

- Does `herdr agent run` pass environment variables through? See item 2.
- Which machine runs the board, and what are the machines' ssh host names?
- Which numbers should Forge's jobs report as `[metric]` lines? The spec's
  example is `residual`, `rate`, `cost`, and `tokens`; a project lists the
  ones it wants first with `"metrics": [...]` in `.agent-stream/config.json`.
- Section 11 of `docs/design.md` keeps the questions from the first two
  rounds that are still open: the dispatcher, the default record root, the
  pinned footer, and the ACP permission policy.

## Branches

- `claude/agent-terminal-display-redesign-5y2l1y` is the working branch.
  After each merge it restarts from `main`.
- `claude/themes-wip` and `claude/agent-stream-watch-tui` are parked
  snapshots from before the themes and the watcher were finished.
  Everything in them is on `main` in finished form, and merging either
  would undo work. They can be deleted.

## Gotchas that cost time

- Bash 3.2 returns 1 for both a `read -t` timeout and EOF. Tell them apart
  another way (the bridge checks the agent with `kill -0`). macOS CI is the
  only real 3.2 check.
- Lip Gloss v2 always renders full color; the output downsamples. Compare
  text in Go tests with `ansi.Strip`.
- A Unix socket path holds 104 bytes on macOS, and ssh adds 17 characters
  while it binds. The board keeps its ControlMaster socket directory short
  (`ControlDir` in `board.go`).
- Background goroutines in the board outlive a test unless the test waits
  for them. Use `t.Cleanup(b.Wait)`.
- A stale watcher binary looks like a missing feature. Rebuild before you
  judge the run view.
