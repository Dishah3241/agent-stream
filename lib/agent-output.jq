# agent-output.jq: the rendering program behind agent_output_render.
# Selected by $fmt (pi-json | claude-json | cursor-json | grok-json | text),
# one raw input line at a time with cross-line state carried by
# "foreach (inputs, null)" so EOF can raise halt_error(5). See
# lib/agent-output.sh for the protocol evidence.
#
# State fields:
#   act  what to emit for the current line: skip | emit | warn
#   out  the text to emit for the current line
#   w wl we  bad-line count, its input line number, short excerpt
#   saw_delta  text already streamed for the current turn (dedup snapshots)
#   last_text  accumulated/last assistant text (claude/cursor result dedup)
#   tools      id -> tool name for results that omit the name

def init_state:
  { act: "skip", out: "", w: 0, wl: 0, we: "", saw_delta: false, last_text: "",
    tools: {}, mid: false, thinking: false };

# Terminal safety: drop ANSI CSI/OSC sequences and control characters, keep
# line breaks, tabs, and Unicode exactly as they are. Non-strings become
# empty so typed payloads never reach gsub.
def clean:
  if type != "string" then ""
  else
    gsub("\u001b\\[[0-9;:?]*[ -/]*[@-~]"; "")
    | gsub("\u001b\\][^\u0007]*\u0007"; "")
    | gsub("\u001b"; "")
    | gsub("\r\n"; "\n")
    | gsub("\r"; "")
    | gsub("[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]"; "")
  end;

# One compact, single-line summary, truncated to $n characters.
def brief($n):
  if type != "string" then ""
  else
    gsub("\\s+"; " ")
    | if length > $n then .[0:$n] + "..." else . end
  end;

def safe($v):
  ($v // "") | if type == "string" or type == "number" or type == "boolean"
    then (tostring | clean) else "" end;

def safe_brief($v; $n):
  safe($v) | brief($n);

# emit() adds the newline itself: the program runs with jq -j (join
# output) so streaming text is not broken at delta boundaries. raw() emits
# text exactly as given, newlines included (pi/grok/cursor text deltas).
# mid records that raw text left the display mid-line, so the next labeled
# line starts on a fresh line. Neither adds a newline at EOF.
def emit($t):
  .thinking = false
  | .act = "emit"
  | .out = ((if .mid then "\n" else "" end) + $t + "\n")
  | .mid = false;
def raw($t): .act = "emit" | .out = $t | .mid = (($t | endswith("\n")) | not);
# A thinking span is one [think] line, then the reasoning as it arrives.
# The next answer or label starts on its own line.
def think_delta($d):
  if $d == "" then .
  elif .thinking == true then raw($d)
  else
    .thinking = true
    | .act = "emit"
    | .out = ((if .mid then "\n" else "" end) + "[think]\n" + $d)
    | .mid = (($d | endswith("\n")) | not)
  end;
def raw_after_think($t):
  if .thinking == true then
    .thinking = false
    | .act = "emit"
    | .out = ((if .mid then "\n" else "" end) + $t)
    | .mid = (($t | endswith("\n")) | not)
  else raw($t) end;

# Tool arguments: identify the tool, never dump payloads.
def arg_field_order:
  ["path", "file_path", "target_file", "notebook_path", "command", "pattern",
   "url", "query", "file", "dir", "prompt", "description"];

def tool_args($a):
  if ($a | type) == "object" then
    ([arg_field_order[] | select($a[.] != null)] | first) as $k
    | if $k == null then ($a | tostring | clean | brief(80))
      else ($a[$k] | tostring | clean | brief(80)) end
  elif ($a | type) == "null" then ""
  else ($a | tostring | clean | brief(80)) end;

# Typed tool results: walk string / {type:text} arrays / known object
# wrappers. Never pass an array or object to gsub, never dump the whole
# payload (brief is applied after flattening).
def as_text($v):
  if ($v | type) == "string" then $v
  elif ($v | type) == "number" or ($v | type) == "boolean" then ($v | tostring)
  elif ($v | type) == "null" then ""
  elif ($v | type) == "array" then
    ($v | map(
      if type == "string" then .
      elif type == "object" then
        if (.type // "") == "text" then as_text(.text // "")
        elif (.type // "") == "image" then "[image]"
        else ((.type // "?") | tostring)
        end
      else as_text(.)
      end) | join(" "))
  elif ($v | type) == "object" then
    ([$v.output, $v.content, $v.text, $v.message, $v.error, $v.detail]
     | map(select(. != null)) | first) as $inner
    | if $inner == null then ""
      else as_text($inner)
      end
  else ""
  end;

def tool_result($r):
  as_text($r) | clean | brief(160);

# pi event types that are real activity but deliberately stay quiet here.
def pi_quiet:
  ["agent_start", "turn_start", "turn_end", "agent_settled", "queue_update",
   "entry_appended", "session_info_changed", "thinking_level_changed",
   "auto_retry_end", "summarization_retry_attempt_start",
   "summarization_retry_finished", "bash_execution_update",
   "tool_execution_update"];

def claude_quiet:
  ["control_request", "control_response", "keepalive", "rate_limit_event"];

def claude_system_quiet:
  ["thinking_tokens", "hook_started", "hook_response"];

def grok_quiet:
  ["usage", "available_commands"];

# Claude: content blocks arrive as complete messages, so each rendered
# piece is a full line appended to .out; the tool id -> name map lets tool
# results carry the tool's name.
def claude_block_out($c):
  ($c.type // "?") as $ct
  | if $ct == "text" then
      ($c.text // "" | clean) as $txt
      | (if ($txt | gsub("^\\s+|\\s+$"; "") | length) > 0
         then ($txt | sub("\n+$"; "")) + "\n"
         else "" end)
    elif $ct == "tool_use" then
      "[tool] \(safe_brief($c.name // "tool"; 40)) \(tool_args($c.input))\n"
    elif $ct == "thinking" then
      ($c.thinking // "" | clean) as $txt
      | if ($txt | gsub("^\\s+|\\s+$"; "") | length) > 0
        then "[think]\n" + ($txt | sub("\n+$"; "")) + "\n"
        else "" end
    elif $ct == "redacted_thinking" then
      ""
    else
      "[note] assistant content: \(safe_brief($ct; 40))\n"
    end;

def claude_tool_result_out($c; $tools):
  ($tools[$c.tool_use_id] // "tool") as $name
  | if ($c.is_error // false)
      then "[error] \($name): \(tool_result($c.content))\n"
      else "[done] \($name)\n"
    end;

def result_closer($ev):
  "[run] result \(safe_brief($ev.subtype // "unknown"; 40))"
  + (if ($ev.duration_ms | type) == "number"
      then " (\($ev.duration_ms)ms, \($ev.num_turns // "?") turns)"
     else "" end);

def claude_event($ev):
  ($ev.type // "?") as $t
  | if $t == "system" then
      if ($ev.subtype // "") == "init" then
        emit("[run] claude \(safe_brief($ev.model // "?"; 40)) session \(safe($ev.session_id // "?") | .[0:8])")
      elif ($ev.subtype // "") == "can_use_tool" then
        emit("[wait] permission: \(safe_brief($ev.tool_name // $ev.tool // "request"; 60))")
      elif (claude_system_quiet | index($ev.subtype // "")) then
        .
      else . end
    elif $t == "stream_event" then
      .
    elif $t == "assistant" then
      ($ev.message.content // "") as $content
      | (if ($content | type) == "string" then [{type: "text", text: $content}]
         elif ($content | type) == "array" then $content
         else [] end) as $blocks
      | reduce ($blocks | to_entries)[] as $b (
          .;
          ($b.value) as $c
          | .out = ((.out // "") + claude_block_out($c))
          | (if ($c.type // "") == "text" and (($c.text // "") | type) == "string" and $c.text != ""
               then .last_text = $c.text
             elif ($c.type // "") == "tool_use" and (($c.id // "") | type) == "string" and $c.id != ""
               then .tools = (.tools + {($c.id): safe($c.name // "tool")})
             else . end)
          | (if (.out // "") != "" then .act = "emit" else . end))
    elif $t == "user" then
      ($ev.message.content // "") as $content
      | (if ($content | type) == "array" then $content else [] end) as $blocks
      | reduce ($blocks | to_entries)[] as $b (
          .;
          ($b.value) as $c
          | if ($c.type // "") == "tool_result"
              then .out = ((.out // "") + claude_tool_result_out($c; .tools)) | .act = "emit"
              else . end)
    elif $t == "result" then
      (if (($ev.result // "") | type) == "string" then $ev.result else "" end) as $txt
      | (if (($ev.is_error // false) or (($ev.subtype // "success") != "success")) then
          (tool_result($ev.result // "")) as $d
          | (if $d == ""
              then "[error] result \(safe_brief($ev.subtype // "unknown"; 40))\n"
              else "[error] result \(safe_brief($ev.subtype // "unknown"; 40)): \($d)\n"
              end)
        elif $txt == .last_text then
          result_closer($ev) + "\n"
        elif ($txt | clean | gsub("^\\s+|\\s+$"; "") | length) > 0 then
          (($txt | clean) | sub("\n+$"; "")) + "\n" + result_closer($ev) + "\n"
        else
          result_closer($ev) + "\n"
        end) as $out
      | .act = "emit"
      | .out = ((if .mid then "\n" else "" end) + $out)
      | .mid = false
      | .thinking = false
    elif (claude_quiet | index($t)) then
      .
    else
      emit("[note] unhandled claude event type: \(safe_brief($t; 40))")
    end;

def pi_event($ev):
  ($ev.type // "?") as $t
  | if $t == "session" then
      emit("[run] pi session \(safe($ev.id // "?") | .[0:8])")
    elif $t == "message_update" then
      (if (($ev.assistantMessageEvent // null) | type) == "object"
         then $ev.assistantMessageEvent else {} end) as $a
      | if ($a.type // "") == "text_delta" then
          (if ($a.delta | type) == "string" then $a.delta else "" end | clean) as $d
          | (if $d == "" then . else .saw_delta = true | raw_after_think($d) end)
        elif ($a.type // "") == "thinking_delta" then
          think_delta(if ($a.delta | type) == "string" then $a.delta else "" end | clean)
        elif ($a.type // "") == "error" then
          emit("[error] \(safe_brief($a.error.errorMessage // $a.reason // "error"; 200))")
        else . end
    elif $t == "message_start" then
      (if (($ev.message.role // "") == "assistant") then .saw_delta = false else . end)
    elif $t == "message_end" then
      ($ev.message // {}) as $m
      | if (($m | type) != "object") then .
        elif (($m.role // "") == "assistant") then
          (if (($m.stopReason // "") == "error" or ($m.stopReason // "") == "aborted") then
             emit("[error] \(safe_brief($m.errorMessage // $m.stopReason; 200))")
           elif (.saw_delta | not) then
             ([($m.content // []) | if type == "array" then .[] else empty end
               | select(.type == "text") | .text
               | if type == "string" then . else empty end] | join("")) as $txt
             | (if ($txt | clean | gsub("^\\s+|\\s+$"; "") | length) > 0 then raw($txt | clean) else . end)
           else . end)
          | .saw_delta = false
        else . end
    elif $t == "tool_execution_start" then
      emit("[tool] \(safe_brief($ev.toolName // "tool"; 40)) \(tool_args($ev.args))")
    elif $t == "tool_execution_end" then
      (if ($ev.isError == true)
        then emit("[error] \(safe_brief($ev.toolName // "tool"; 40)): \(tool_result($ev.result))")
        else emit("[done] \(safe_brief($ev.toolName // "tool"; 40))") end)
    elif $t == "auto_retry_start" then
      emit("[wait] retry \(safe($ev.attempt))/\(safe($ev.maxAttempts)) in \(safe($ev.delayMs))ms: \(safe_brief($ev.errorMessage // ""; 120))")
    elif $t == "compaction_start" then
      emit("[wait] compacting context (\(safe_brief($ev.reason // "unknown"; 40)))")
    elif $t == "compaction_end" then
      (if ($ev.aborted // false) then emit("[error] compaction aborted") else . end)
    elif $t == "agent_end" then
      (if ($ev.willRetry // false) then emit("[wait] retrying") else . end)
    elif $t == "summarization_retry_scheduled" then
      emit("[wait] summarization retry \(safe($ev.attempt))/\(safe($ev.maxAttempts)) in \(safe($ev.delayMs))ms: \(safe_brief($ev.errorMessage // ""; 120))")
    elif (pi_quiet | index($t)) then
      .
    else
      emit("[note] unhandled pi event type: \(safe_brief($t; 40))")
    end;

# Cursor: *ToolCall nested object names the tool (readToolCall -> read).
def cursor_tool_key($tc):
  if ($tc | type) != "object" then null
  else ([($tc | keys[]) | select(endswith("ToolCall"))] | first)
  end;

def cursor_tool_name($tc):
  cursor_tool_key($tc) as $k
  | if $k == null then "tool"
    else ($k | sub("ToolCall$"; "") | if . == "" then "tool" else . end)
    end;

def cursor_tool_args($tc):
  cursor_tool_key($tc) as $k
  | if $k == null then ""
    else tool_args($tc[$k].args // {})
    end;

def cursor_tool_ok($tc):
  cursor_tool_key($tc) as $k
  | if $k == null then true
    else
      ($tc[$k].result // {}) as $r
      | if ($r | type) != "object" then true
        elif ($r.error != null or $r.failure != null or $r.isError == true
              or $r.rejected != null or $r.denied != null) then false
        else true
        end
    end;

def cursor_tool_error($tc):
  cursor_tool_key($tc) as $k
  | if $k == null then ""
    else tool_result(($tc[$k].result.error // $tc[$k].result.failure // $tc[$k].result))
    end;

def cursor_assistant_text($ev):
  ($ev.message.content // "") as $content
  | if ($content | type) == "string" then $content
    elif ($content | type) == "array" then
      ([ $content[]
         | select((.type // "") == "text")
         | .text
         | if type == "string" then . else empty end ] | join(""))
    else ""
    end;

def cursor_event($ev):
  ($ev.type // "?") as $t
  | if $t == "system" then
      if ($ev.subtype // "") == "init" then
        emit("[run] cursor \(safe_brief($ev.model // "?"; 40)) session \(safe($ev.session_id // "?") | .[0:8])")
      else . end
    elif $t == "user" then
      .
    elif $t == "thinking" then
      if ($ev.subtype // "delta") == "delta" then
        think_delta(if ($ev.text | type) == "string" then $ev.text else "" end | clean)
      else . end
    elif $t == "assistant" then
      (cursor_assistant_text($ev) | clean) as $clean
      | (($ev | has("timestamp_ms")) and (($ev | has("model_call_id")) | not)) as $partial
      | if $partial then
          # Whitespace-only partials are real deltas (a, " ", b → "a b").
          if $clean == "" then .
          else .saw_delta = true | .last_text = (.last_text + $clean) | raw_after_think($clean)
          end
        elif ($clean | gsub("^\\s+|\\s+$"; "") | length) == 0 then .
        elif .saw_delta then
          .
        else
          .last_text = $clean | raw_after_think($clean)
        end
    elif $t == "tool_call" then
      ($ev.tool_call // {}) as $tc
      | safe_brief(cursor_tool_name($tc); 40) as $name
      | if ($ev.subtype // "") == "started" then
          emit("[tool] \($name) \(cursor_tool_args($tc))")
        elif ($ev.subtype // "") == "completed" then
          if cursor_tool_ok($tc)
            then emit("[done] \($name)")
            else emit("[error] \($name): \(cursor_tool_error($tc))")
          end
        else . end
    elif $t == "result" then
      (if (($ev.result // "") | type) == "string" then $ev.result else "" end) as $txt
      | (if (($ev.is_error // false) or (($ev.subtype // "success") != "success")) then
          (tool_result($ev.result // "")) as $d
          | (if $d == ""
              then "[error] result \(safe_brief($ev.subtype // "unknown"; 40))\n"
              else "[error] result \(safe_brief($ev.subtype // "unknown"; 40)): \($d)\n"
              end)
        elif .saw_delta or $txt == .last_text then
          result_closer($ev) + "\n"
        elif ($txt | clean | gsub("^\\s+|\\s+$"; "") | length) > 0 then
          (($txt | clean) | sub("\n+$"; "")) + "\n" + result_closer($ev) + "\n"
        else
          result_closer($ev) + "\n"
        end) as $out
      | .act = "emit"
      | .out = ((if .mid then "\n" else "" end) + $out)
      | .mid = false
      | .thinking = false
    else
      emit("[note] unhandled cursor event type: \(safe_brief($t; 40))")
    end;

def grok_event($ev):
  ($ev.type // "?") as $t
  | if $t == "text" then
      (if ($ev.data | type) == "string" then $ev.data else "" end | clean) as $d
      | (if $d == "" then . else .saw_delta = true | .last_text = (.last_text + $d) | raw_after_think($d) end)
    elif $t == "thought" then
      think_delta(if ($ev.data | type) == "string" then $ev.data else "" end | clean)
    elif $t == "tool_call" then
      (if ($ev.toolCallId | type) == "string" then $ev.toolCallId else "" end) as $id
      | safe_brief($ev.toolName // $ev.title // "tool"; 40) as $name
      | .tools = (if $id != "" then .tools + {($id): $name} else .tools end)
      | emit("[tool] \($name) \(tool_args($ev.rawInput // {}))")
    elif $t == "tool_call_update" then
      (if ($ev.toolCallId | type) == "string" then $ev.toolCallId else "" end) as $id
      | (.tools[$id] // "tool") as $name
      | if ($ev.status // "") == "completed" then
          emit("[done] \($name)")
        elif ($ev.status // "") == "failed" then
          emit("[error] \($name): \(tool_result($ev.rawOutput // $ev.content))")
        else .
        end
    elif $t == "end" then
      emit("[run] result \(safe_brief($ev.stopReason // "end"; 40))")
    elif (grok_quiet | index($t)) then
      .
    else
      emit("[note] unhandled grok event type: \(safe_brief($t; 40))")
    end;

def handle($ev):
  if $fmt == "pi-json" then pi_event($ev)
  elif $fmt == "claude-json" then claude_event($ev)
  elif $fmt == "cursor-json" then cursor_event($ev)
  elif $fmt == "grok-json" then grok_event($ev)
  else . end;

def mark_bad($why):
  .w += 1
  | .wl = input_line_number
  | .we = $why
  | .act = "warn";

init_state
| foreach (inputs, null) as $line (
    .;
    if $line == null then
      if .w > 0 then
        "agent-output: \(.w) malformed event line(s) skipped\n" | halt_error(5)
      else
        .
      end
    else
      .act = "skip" | .out = ""
      | if $fmt == "text" then
          emit($line | clean | gsub("(?<pre>[^\\s])(?<info>INFO )"; "\(.pre)\n\(.info)"))
        elif ($line | clean | gsub("^\\s+|\\s+$"; "") | length) == 0 then
          .
        elif ([$line | fromjson?] | length) == 0 then
          mark_bad($line | clean | brief(60))
        elif ([$line | fromjson?][0] | type) == "object" then
          ([$line | fromjson?][0]) as $ev
          | . as $st
          | try ($st | handle($ev)) catch
              ($st | mark_bad("invalid event shape"))
        else
          mark_bad("non-object JSON event")
        end
    end;
    if $line == null then empty
    elif .act == "emit" then .out
    elif .act == "warn" then
      if .we == "invalid event shape" or .we == "non-object JSON event" then
        "[warn] skipped event near input line \(.wl): \(.we)\n"
      else
        "[warn] malformed JSON event near input line \(.wl), skipped: \(.we)\n"
      end
    else empty end
  )
