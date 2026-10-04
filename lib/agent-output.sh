#!/usr/bin/env bash
# agent-output.sh: render harness event streams into readable activity.
# Sourced by agent-run (integration owned elsewhere); the public seam is
#
#   agent_output_render FORMAT < events.jsonl > display.txt
#
# FORMAT is one of pi-json, claude-json, cursor-json, grok-json, acp-json, text;
# anything else is rejected with a usage diagnostic and exit 2. The
# space-separated AGENT_OUTPUT_FORMATS string is a list for callers, never
# itself a valid FORMAT. The renderer is pure: it consumes stdin and writes
# human-readable activity to stdout. It never dispatches a session, persists
# anything, or writes record markers; capture and status belong to the caller.
#
# Event shapes, read from installed sources and completed private probes
# rather than assumed:
#
#   pi      pi 0.85.1 --mode json. One JSON object per line: session,
#           message_update assistantMessageEvent text_delta, message_end,
#           tool_execution_start/update/end. Real tool results use
#           result.content as an array of {type:text,text} objects.
#           Thinking deltas stream after a [think] line. Whole tool
#           payloads are never dumped.
#
#   claude  claude --output-format stream-json --verbose. system/init,
#           assistant content text/tool_use/thinking, user tool_result,
#           result success|error_*, and expected rate_limit_event (quiet).
#           stream_event wrappers are dropped. Result text is not reprinted
#           when it duplicates the last assistant text.
#
#   cursor  cursor-agent --output-format stream-json --stream-partial-output.
#           assistant partials have timestamp_ms and no model_call_id; full
#           intermediate snapshots have both; the final snapshot has neither.
#           Result concatenates assistant segments. tool_call
#           started/completed uses call_id and nested *ToolCall.args/result
#           (for example readToolCall), not Claude content-block events.
#           Deduplicate snapshots and the final result when partials already
#           rendered. Thinking deltas stream after a [think] line. Whole
#           tool payloads stay hidden.
#
#   grok    grok --output-format streaming-json. Flat {type:text,data} deltas,
#           tool_call (toolCallId, toolName, rawInput, status=pending),
#           tool_call_update (same id, status null|completed|failed), end.
#           Thought deltas stream after a [think] line. Ignore usage,
#           signature, available_commands, and whole tool content/rawOutput.
#
#   acp     Agent Client Protocol agents (newline-delimited JSON-RPC on the
#           agent's stdout, protocol 1 and the v2 schema). Shapes come from
#           the published @agentclientprotocol/sdk JSON schemas, read in
#           full; no ACP agent was run here. session/update notifications,
#           session/request_permission requests, and the responses to
#           initialize / session/new / session/prompt are rendered; the
#           bridge in bin/agent-stream drives an agent through those
#           three requests and answers permission requests.
#
#   claude  Claude Code 2.1 adds (observed in real runs here): TaskCreate /
#           TaskUpdate / TaskList as the plan tools (TodoWrite is gone from
#           that build but still handled), system task_summary (a one-line
#           "what I am doing"), post_turn_summary (status_detail,
#           needs_action), task_started / task_progress / task_notification
#           around subagents, control_request can_use_tool when the
#           dispatcher wires --permission-prompt-tool stdio, top-level
#           active_goal and autocompact_state (quiet), and
#           result.permission_denials.
#
#   text    not JSON: worker lines pass through sanitized. Native Codex,
#           and OpenCode text output use this mode. Installed
#           OpenCode help supports JSON; no JSON adapter is assigned here.
#
# Implementation: one jq process per render (jq -R line input, foreach
# inputs for cross-line state, --unbuffered -j so newline-free text is
# visible before input closes). No sidecar line-reader and no pipeline, so
# a jq failure is this function's status even when the caller has pipefail
# off. A line that does not parse as JSON, or is JSON but not an object, is
# diagnosed, the stream is drained to EOF, and jq exits 5. Handler throws
# on an invalid shape are caught the same way. Thinking text is shown
# after a [think] line; signatures and tool bodies stay hidden.
#
# Bash 3.2 compatible; needs jq (already a dependency of this repository).

# AGENT_OUTPUT_FORMATS lists the supported formats for callers (argv
# construction and validation belong to the integration); agent_output_render
# validates FORMAT by word membership, never by treating this string as one
# format name.
AGENT_OUTPUT_FORMATS="pi-json claude-json cursor-json grok-json acp-json text"

# Directory of this file, resolved once at source time so a later
# BASH_SOURCE[0] (eval, sourced-from-stdin) cannot point jq at cwd.
_AGENT_OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_agent_output_dir() {
  printf '%s\n' "$_AGENT_OUTPUT_DIR"
}

# Word membership only: "pi-json claude-json ..." is not a format.
# Split on spaces ourselves so a caller IFS (or a trailing NUL) cannot
# make a real format miss, and so the whole list string never matches.
_agent_output_known_format() {
  local f rest
  rest="$AGENT_OUTPUT_FORMATS"
  while [[ -n "$rest" ]]; do
    f="${rest%% *}"
    rest="${rest#"$f"}"
    rest="${rest# }"
    if [[ -n "$f" && "$1" == "$f" ]]; then
      return 0
    fi
  done
  return 1
}

agent_output_render() {
  if [[ $# -ne 1 ]]; then
    printf 'agent-output: usage: agent_output_render FORMAT (supported: %s)\n' \
      "$AGENT_OUTPUT_FORMATS" >&2
    return 2
  fi
  if ! _agent_output_known_format "$1"; then
    printf 'agent-output: unknown format "%s" (supported: %s)\n' \
      "$1" "$AGENT_OUTPUT_FORMATS" >&2
    return 2
  fi
  local dir rc
  dir="$(_agent_output_dir)" || return 1
  # Direct jq to stdout: no awk line-reader, no pipeline to mask jq errors.
  jq -Rnj --unbuffered --arg fmt "$1" -f "$dir/agent-output.jq"
  rc=$?
  return "$rc"
}
