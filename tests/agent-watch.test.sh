#!/usr/bin/env bash
set -euo pipefail

# agent-stream watch: the subcommand finds the watcher or says how to build
# it, and the watcher reads a record produced end to end by an ACP protocol
# 2 agent through the bridge. The watcher half runs only when
# AGENT_STREAM_WATCH names a built binary (the Go CI job sets it); the Go
# tests in cmd/agent-stream-watch cover the interactive views.

fail() { echo "agent-watch test: ${*:-assertion failed at line ${BASH_LINENO[0]}}" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/agent-stream"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset NO_COLOR AGENT_RUN_COLOR AGENT_STREAM_ACP_VERSION AGENT_STREAM_ACP_PERMISSION
export AGENT_STREAM_HOME="$TMP/home" LC_ALL=C TERM=xterm
WATCH="${AGENT_STREAM_WATCH:-}"

# A missing binary is a clear message with the build command, exit 127.
rc=0
AGENT_STREAM_WATCH="$TMP/nope" "$BIN" watch >/dev/null 2>"$TMP/err" || rc=$?
[[ "$rc" == 127 ]] || fail "a missing watcher exits 127, got $rc"
grep -q 'go build -o ../../bin/agent-stream-watch' "$TMP/err" || fail "the message says how to build it: $(cat "$TMP/err")"
grep -q 'agent-stream follow' "$TMP/err" || fail "the message names the fallback"

if [[ -z "$WATCH" ]]; then
  echo "agent-watch test: all assertions passed (watcher binary not given, skipped its half)"
  exit 0
fi
[[ -x "$WATCH" ]] || fail "AGENT_STREAM_WATCH is not executable: $WATCH"

cat >"$TMP/fake-acp2" <<'AGENT'
#!/usr/bin/env bash
u() { printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":%s}}\n' "$1"; }
while IFS= read -r line; do
  method="$(printf '%s' "$line" | jq -r '.method // ""')"
  id="$(printf '%s' "$line" | jq -c '.id // empty')"
  case "$method" in
    initialize) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":2,"info":{"name":"watch-agent","version":"1"},"capabilities":{}}}\n' "$id" ;;
    session/new) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"sess-watch"}}\n' "$id" ;;
    session/prompt)
      printf '{"jsonrpc":"2.0","id":%s,"result":{"messageId":"m0"}}\n' "$id"
      u '{"sessionUpdate":"state_update","state":"running"}'
      u '{"sessionUpdate":"plan_update","plan":{"type":"items","planId":"p","entries":[{"content":"Look","priority":"high","status":"completed"},{"content":"Report","priority":"low","status":"completed"}]}}'
      u '{"sessionUpdate":"tool_call_update","toolCallId":"t","title":"List files","kind":"search","status":"completed"}'
      u '{"sessionUpdate":"agent_message","messageId":"m1","content":[{"type":"text","text":"Watched and done."}]}'
      u '{"sessionUpdate":"state_update","state":"idle","stopReason":"end_turn","usage":{"totalTokens":42,"inputTokens":40,"outputTokens":2}}' ;;
  esac
done
AGENT
chmod +x "$TMP/fake-acp2"
mkdir -p "$TMP/proj"
( cd "$TMP/proj" && "$BIN" run --agent acp --task "Watch me" --project watched --id w1 -- "$TMP/fake-acp2" ) >/dev/null 2>&1 \
  || fail "the ACP run behind the watcher failed"

# Piped stdout: the fleet table, printed once, no terminal controls.
AGENT_STREAM_WATCH="$WATCH" "$BIN" watch >"$TMP/table" 2>"$TMP/err" || fail "watch exit: $(cat "$TMP/err")"
grep -q '^  STATE' "$TMP/table" || fail "the table has a heading: $(cat "$TMP/table")"
grep -q 'success' "$TMP/table" || fail "the run row says success: $(cat "$TMP/table")"
grep -q 'watched' "$TMP/table" || fail "the run row names the project"
grep -q '2/2' "$TMP/table" || fail "the run row shows the plan progress"
grep -q 'Watched and done.' "$TMP/table" || fail "the run row says how it ended"
grep -q $'\x1b' "$TMP/table" && fail "piped output carries no escape sequences"
LC_ALL=C grep -q '[^ -~]' "$TMP/table" && fail "a C locale gets ASCII marks only: $(cat "$TMP/table")"

# --once on a record directory, with a UTF-8 locale for Unicode marks.
for _l in C.UTF-8 en_US.UTF-8 en_US.utf8; do
  if [[ -z "$(LC_ALL=$_l bash -c ':' 2>&1)" ]]; then export LC_ALL="$_l"; break; fi
done
AGENT_STREAM_WATCH="$WATCH" "$BIN" watch --once "$AGENT_STREAM_HOME/runs/w1" >"$TMP/one" || fail "watch --once on a record"
[[ "$(wc -l <"$TMP/one" | tr -d ' ')" == 2 ]] || fail "one record is a heading and one row: $(cat "$TMP/one")"
if [[ "$LC_ALL" == *[Uu][Tt][Ff]* ]]; then
  grep -q '✓ success' "$TMP/one" || fail "a UTF-8 locale gets the check mark: $(cat "$TMP/one")"
fi

# An empty root says so instead of failing.
mkdir -p "$TMP/empty"
AGENT_STREAM_WATCH="$WATCH" "$BIN" watch "$TMP/empty" >"$TMP/none" || fail "an empty root is not an error"
grep -qx 'no runs' "$TMP/none" || fail "an empty root says no runs"

echo "agent-watch test: all assertions passed"
