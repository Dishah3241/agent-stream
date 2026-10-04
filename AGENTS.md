# agent-stream

Bash libraries that render, style, and capture coding-agent output. `README.md` describes the three stages and the record files.

- Keep every library Bash 3.2 compatible: no `mapfile`, associative arrays, or `${var,,}`. macOS runs the tests on `/bin/bash` 3.2.
- Runtime dependencies are `bash` and `jq`. `python3` stays optional. Do not add another.
- The label lines (`[tool]`, `[done]`, `[error]`, `[warn]`, `[note]`, `[think]`) are the contract between `agent_output_render` and `agent_present_stream`. Change both sides and both test files together.
- Never print a tool payload, a thinking signature, or an unsanitized terminal control sequence. The tests assert each one.
- Add an adapter by reading the harness's real event stream first. Record the evidence in the header comment of `lib/agent-output.sh` and add fixture events to `tests/agent-output.test.sh`.
- Verify with `for t in tests/*.test.sh; do bash "$t"; done`, then `bash -n` and `shellcheck -S error` on every file in `lib/` and `tests/`. Run the tests under `/bin/bash` on macOS as well.
- This repository is public. Do not commit hostnames, addresses, home paths, credentials, or agent transcripts.
