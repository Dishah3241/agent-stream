# agent-stream

Bash libraries and one command that render, style, track, and capture coding-agent output. `README.md` describes the stages and the record files; `docs/design.md` records the decisions.

- Keep every library Bash 3.2 compatible: no `mapfile`, associative arrays, `${var,,}`, or fractional `read -t`, and never tell a `read -t` timeout from EOF by its status (3.2 returns 1 for both; the status above 128 is Bash 4). macOS runs the tests on `/bin/bash` 3.2.
- Runtime dependencies are `bash` and `jq`. `python3` and `git` stay optional. Do not add another.
- The activity line protocol (`[run]`, `[tool]`, `[done]`, `[error]`, `[warn]`, `[note]`, `[think]`, `[wait]`, `[todo]`, `[step]`, `[end]`) is the contract between `agent_output_render`, `agent_present_stream`, and `agent_state_track`. Change all three sides and their test files together, and keep every line self-contained so a `tail -f` reader needs no context.
- `display.txt` is plain append-only text. Anything that redraws (the status card, the pinned footer) is terminal-only and lives in `lib/agent-present.sh`.
- `state.json` is derived from `display.txt` lines, never from events. If a fact belongs in the state, it belongs in the protocol first.
- Never print a tool payload, a thinking signature, or an unsanitized terminal control sequence. The tests assert each one.
- Add an adapter by reading the harness's real event stream first. Record the evidence in the header comment of `lib/agent-output.sh`, add fixture events to `tests/agent-output.test.sh`, and say in the comment which shapes were observed and which are assumptions.
- Verify with `for t in tests/*.test.sh; do bash "$t"; done`, then `bash -n` and `shellcheck -S error` on every file in `lib/`, `bin/`, and `tests/`. Run the tests under `/bin/bash` on macOS as well.
- This repository is public. Do not commit hostnames, addresses, home paths, credentials, or agent transcripts. Fixtures must be synthetic or scrubbed.
