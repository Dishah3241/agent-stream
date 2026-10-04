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

# ------------------------------------------------------------------ board ---
# agent-stream board over a stand-in ssh that runs the remote command here:
# a real run nested under its parent, a local machine, and one that refuses.

cat >"$TMP/ssh" <<'S'
#!/bin/sh
while [ $# -gt 0 ]; do case $1 in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
host=$1; shift
[ "$host" = dead ] && { echo "ssh: connect to host dead: Connection refused" >&2; exit 255; }
exec sh -c "$*"
S
chmod +x "$TMP/ssh"
printf 'echo working\n' >"$TMP/w.sh"
cat >"$TMP/outer.sh" <<W
#!/usr/bin/env bash
AGENT_STREAM_HOME="$TMP/forge" "$BIN" run --agent codex --task inner --id inner1 -- bash "$TMP/w.sh" >/dev/null 2>&1
W
AGENT_STREAM_HOME="$TMP/forge" "$BIN" run --agent codex --task outer --project fleet --id outer1 -- bash "$TMP/outer.sh" >/dev/null 2>&1 \
  || fail "the nested run"
cat >"$TMP/board.json" <<J
{"machines": [{"name": "forge", "ssh": "forge.example", "root": "$TMP/forge/runs"},
              {"name": "here", "local": true, "root": "$AGENT_STREAM_HOME/runs"},
              {"name": "air", "ssh": "dead"}]}
J
AGENT_STREAM_SSH="$TMP/ssh" AGENT_STREAM_WATCH="$WATCH" COLUMNS=120 \
  "$BIN" board "$TMP/board.json" --once >"$TMP/board" 2>"$TMP/err" || fail "board exit: $(cat "$TMP/err")"
grep -q '^MACHINE' "$TMP/board" || fail "the board has a MACHINE column: $(cat "$TMP/board")"
grep -q '^forge .* fleet' "$TMP/board" || fail "the forge run is under forge: $(cat "$TMP/board")"
grep -Eq '(└|`-) ' "$TMP/board" || fail "the inner run is nested under the outer one: $(cat "$TMP/board")"
grep -q '^here ' "$TMP/board" || fail "the local machine is listed: $(cat "$TMP/board")"
grep -q '^air .*no signal.*Connection refused' "$TMP/board" || fail "an unreachable machine is no signal: $(cat "$TMP/board")"
rc=0
AGENT_STREAM_WATCH="$WATCH" "$BIN" board "$TMP/missing.json" --once >/dev/null 2>"$TMP/err" || rc=$?
[[ "$rc" == 2 ]] && grep -q 'missing.json' "$TMP/err" || fail "a missing board.json is a usage error naming it"

# --------------------------------------------------------- board, real ssh ---
# Opt-in (AGENT_STREAM_REAL_SSH=1, CI sets it): a private sshd on a loopback
# port with throwaway keys, and the board through the real ssh client and its
# ControlMaster. sshd runs as the current user, so it can only log in as them.

if [[ "${AGENT_STREAM_REAL_SSH:-}" == 1 ]]; then
  SSHD="$(command -v sshd || true)"
  [[ -n "$SSHD" ]] || { [[ -x /usr/sbin/sshd ]] && SSHD=/usr/sbin/sshd; }
  [[ -n "$SSHD" ]] || fail "AGENT_STREAM_REAL_SSH=1 needs sshd"
  command -v ssh >/dev/null || fail "AGENT_STREAM_REAL_SSH=1 needs ssh"
  S="$TMP/sshd"
  mkdir -p "$S" "$S/home" && chmod 700 "$S"
  ssh-keygen -q -t ed25519 -N '' -f "$S/host_key" || fail "host key"
  ssh-keygen -q -t ed25519 -N '' -f "$S/user_key" || fail "user key"
  cp "$S/user_key.pub" "$S/authorized_keys"
  port=$(( 20000 + $$ % 20000 ))
  cat >"$S/sshd_config" <<C
Port $port
ListenAddress 127.0.0.1
HostKey $S/host_key
AuthorizedKeysFile $S/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
StrictModes no
UsePAM no
PidFile $S/sshd.pid
C
  # Root's sshd wants its privilege separation directory.
  if [[ "$(id -u)" == 0 ]]; then mkdir -p /run/sshd; fi
  # Stop sshd and any shared connection even when an assertion fails.
  real_ssh_cleanup() {
    [[ -f "$S/sshd.pid" ]] && kill "$(cat "$S/sshd.pid")" 2>/dev/null
    find "$S/home" "$S/cache" -type s 2>/dev/null | while IFS= read -r s; do
      ssh -S "$s" -O exit forge-real >/dev/null 2>&1
    done
    rm -rf "$TMP"
  }
  trap real_ssh_cleanup EXIT
  "$SSHD" -f "$S/sshd_config" -E "$S/sshd.log" || fail "sshd did not start: $(cat "$S/sshd.log" 2>/dev/null)"
  cat >"$S/ssh_config" <<C
Host forge-real
  HostName 127.0.0.1
  Port $port
  User $(id -un)
  IdentityFile $S/user_key
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile $S/known_hosts
  LogLevel ERROR
C
  # Wait for sshd to accept a login.
  i=0
  until ssh -F "$S/ssh_config" -o BatchMode=yes forge-real true 2>"$S/login.err"; do
    i=$((i + 1))
    [[ $i -lt 50 ]] || fail "no login to the private sshd: $(cat "$S/login.err") $(cat "$S/sshd.log")"
    sleep 0.1
  done
  printf '{"machines": [{"name": "forge", "ssh": "forge-real", "root": "%s/forge/runs"}]}\n' "$TMP" >"$S/board.json"
  # The cache directory, which holds the ControlMaster socket, under $S.
  board_env() { HOME="$S/home" XDG_CACHE_HOME="$S/cache" AGENT_STREAM_SSH="ssh -F $S/ssh_config" \
    AGENT_STREAM_WATCH="$WATCH" COLUMNS=120 "$@"; }
  board_env "$BIN" board "$S/board.json" --once >"$TMP/realboard" 2>"$TMP/err" || fail "board over real ssh: $(cat "$TMP/err")"
  grep -q '^forge .* fleet' "$TMP/realboard" || fail "real ssh: the forge run is listed: $(cat "$TMP/realboard") $(cat "$TMP/err")"
  grep -Eq '(└|`-) ' "$TMP/realboard" || fail "real ssh: the inner run is nested: $(cat "$TMP/realboard")"
  sock="$(find "$S/home" "$S/cache" -type s 2>/dev/null | head -n 1)"
  [[ -n "$sock" ]] || fail "real ssh: the ControlMaster socket persists between polls"
  # A second board reuses the master: it still answers with sshd gone.
  kill "$(cat "$S/sshd.pid")" && rm -f "$S/sshd.pid"
  board_env "$BIN" board "$S/board.json" --once >"$TMP/realboard2" 2>"$TMP/err" || fail "second board: $(cat "$TMP/err")"
  grep -q '^forge .* fleet' "$TMP/realboard2" || fail "real ssh: the second board rides the shared connection: $(cat "$TMP/realboard2")"
  ssh -S "$sock" -O exit forge-real >/dev/null 2>&1 || true
  # With the master gone too, the machine is no signal.
  board_env "$BIN" board "$S/board.json" --once >"$TMP/realboard3" 2>"$TMP/err" || fail "third board: $(cat "$TMP/err")"
  grep -q '^forge .*no signal' "$TMP/realboard3" || fail "real ssh: a refused machine is no signal: $(cat "$TMP/realboard3")"
fi

echo "agent-watch test: all assertions passed"
