# agent-output.jq: the rendering program behind agent_output_render.
# Selected by $fmt (pi-json | claude-json | cursor-json | grok-json | text),
# one raw input line at a time with cross-line state carried by
# "foreach (inputs, null)" so EOF can raise halt_error(5). See
# lib/agent-output.sh for the protocol evidence and docs/design.md for the
# activity line protocol this program emits.
#
# State fields:
#   act  what to emit for the current line: skip | emit | warn
#   out  the text to emit for the current line
#   w wl we  bad-line count, its input line number, short excerpt
#   saw_delta  text already streamed for the current turn (dedup snapshots)
#   last_text  accumulated/last assistant text (claude/cursor result dedup)
#   tools      id -> tool name for results that omit the name
#   todos      the plan as last shown: [{text, status}]
#   task_ids   Claude TaskCreate id -> index into todos
#   pending    Claude tool_use id -> plan operation awaiting its tool_result
#   plan_ids   tool ids whose start was shown as a plan, so no [done] follows

def init_state:
  { act: "skip", out: "", w: 0, wl: 0, we: "", saw_delta: false, last_text: "",
    tools: {}, mid: false, thinking: false, cwd: null,
    todos: [], task_ids: {}, pending: {}, plan_ids: {} };

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
# append($t): add one more full line to what this event already emits.
def append($t):
  .thinking = false
  | .act = "emit"
  | .out = ((.out // "") + (if .mid then "\n" else "" end) + $t + "\n")
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

# Tool arguments: identify the tool, never dump payloads. "description"
# comes before "prompt" so a subagent call shows its one-line description
# rather than the opening of its prompt.
def arg_field_order:
  ["path", "file_path", "target_file", "notebook_path", "command", "pattern",
   "url", "query", "file", "dir", "description", "prompt", "subject", "taskId"];

def path_fields:
  ["path", "file_path", "target_file", "notebook_path", "file", "dir"];

# A path is shown relative to the harness working directory when the stream
# said what that is ($cwd from the init event), and a path that is still too
# long keeps its tail, because the file name is the part a reader needs.
def show_path($p; $cwd):
  ($p | tostring | clean | gsub("\\s+"; " ")) as $s
  | (if ($cwd | type) == "string" and $cwd != "" and ($s | startswith($cwd + "/"))
       then $s[($cwd | length) + 1:] else $s end) as $r
  | if ($r | length) > 80 then "..." + $r[-77:] else $r end;

def tool_args($a; $cwd):
  if ($a | type) == "object" then
    ([arg_field_order[] | select($a[.] != null)] | first) as $k
    | if $k == null then ($a | tostring | clean | brief(80))
      elif (path_fields | index($k)) != null then show_path($a[$k]; $cwd)
      else ($a[$k] | tostring | clean | brief(80)) end
  elif ($a | type) == "null" then ""
  else ($a | tostring | clean | brief(80)) end;

def tool_args($a): tool_args($a; null);

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
    ([$v.output, $v.content, $v.text, $v.message, $v.error, $v.detail,
      $v.stderr, $v.stdout, $v.failure, $v.reason]
     | map(select(. != null and . != "")) | first) as $inner
    | if $inner == null then ""
      else as_text($inner)
      end
  else ""
  end;

def tool_result($r):
  as_text($r) | clean | brief(160);

# ------------------------------------------------------------------ plans --
# The plan protocol: "[todo] I/N STATUS text", one self-contained line per
# item, STATUS in pending | active | done | dropped. The whole list is shown
# when it first appears or changes length; otherwise only changed items.

def todo_status($s):
  (if ($s | type) == "string" then ($s | ascii_downcase) else "" end) as $w
  | if ($w | test("progress|active|doing|running|current|started")) then "active"
    elif ($w | test("complete|done|finished|resolved|closed")) then "done"
    elif ($w | test("cancel|delet|skip|drop|remov|abandon")) then "dropped"
    else "pending" end;

def todo_text($o):
  if ($o | type) == "object" then
    ([$o.content, $o.text, $o.title, $o.subject, $o.description, $o.step, $o.name]
     | map(select(type == "string" and length > 0)) | first) as $t
    | safe_brief($t // ""; 120)
  elif ($o | type) == "string" then safe_brief($o; 120)
  else "" end;

def todo_item($o):
  { text: todo_text($o),
    status: (if ($o | type) == "object" then todo_status($o.status // $o.state // "") else "pending" end) };

# plan_items($a): the array of items behind a plan tool's arguments, or
# null when the arguments carry no plan. Objects with a text field count;
# bare strings count as pending items.
def plan_items($a):
  if ($a | type) != "object" then null
  else
    ([ ($a.todos, $a.items, $a.tasks, $a.plan, $a.steps, $a.todo)
       | select(type == "array" and length > 0
                and all(.[]; type == "object" or type == "string")) ]
     | first) as $arr
    | if $arr == null then null
      else ($arr | map(todo_item(.)) | map(select(.text != ""))) end
  end;

def acp_plan_entries($entries):
  if ($entries | type) != "array" then null
  else [$entries[] | select(type == "object") | todo_item(.)] | map(select(.text != "")) end;

def is_plan_tool($name):
  (if ($name | type) == "string" then ($name | ascii_downcase) else "" end)
  | test("todo|plan|task");

def todo_lines($old; $new):
  ($new | length) as $n
  | ($old | length) as $o
  | if $o < $n and $new[0:$o] == $old then
      # Items were appended: show only the new ones.
      [range($o; $n) | "[todo] \(. + 1)/\($n) \($new[.].status) \($new[.].text)"]
    elif $o != $n then
      [range(0; $n) | "[todo] \(. + 1)/\($n) \($new[.].status) \($new[.].text)"]
    else
      [range(0; $n) | select($old[.] != $new[.])
       | "[todo] \(. + 1)/\($n) \($new[.].status) \($new[.].text)"]
    end;

# set_todos($new): replace the plan and emit what changed.
def set_todos($new):
  todo_lines(.todos; $new) as $ls
  | .todos = $new
  | reduce $ls[] as $l (.; append($l));

# ------------------------------------------------------------ quiet lists --
# pi event types that are real activity but deliberately stay quiet here.
def pi_quiet:
  ["agent_start", "turn_start", "turn_end", "agent_settled", "queue_update",
   "entry_appended", "session_info_changed", "thinking_level_changed",
   "auto_retry_end", "summarization_retry_attempt_start",
   "summarization_retry_finished", "bash_execution_update",
   "tool_execution_update"];

# Claude top-level types seen in real streams that carry no activity.
def claude_quiet:
  ["control_response", "keepalive", "rate_limit_event", "active_goal",
   "autocompact_state", "stream_event"];

def claude_system_quiet:
  ["thinking_tokens", "hook_started", "hook_response", "task_progress",
   "task_updated", "api_retry", "status"];

def grok_quiet:
  ["usage", "available_commands"];

# ------------------------------------------------------------------ claude --
# Content blocks arrive as complete messages, so each rendered piece is a
# full line; the tool id -> name map lets tool results carry the tool's name.

def claude_text_block($txt):
  if ($txt | gsub("^\\s+|\\s+$"; "") | length) > 0
  then append($txt | sub("\n+$"; "")) else . end;

# Plan tools that Claude Code uses: TodoWrite (whole list per call) and the
# TaskCreate / TaskUpdate / TaskList family (incremental, ids assigned by the
# harness and reported in the tool result).
def claude_plan_tool($name):
  ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"] | index($name) != null;

def claude_tool_use($c):
  ($c.name // "tool") as $name
  | (if (($c.id // "") | type) == "string" then $c.id else "" end) as $id
  | (if $id != "" then .tools = (.tools + {($id): safe($name)}) else . end)
  | if $name == "TodoWrite" then
      (plan_items($c.input) // []) as $items
      | if ($items | length) > 0 then set_todos($items) else . end
    elif $name == "TaskCreate" then
      .pending = (.pending + {($id): {op: "create", subject: todo_text($c.input)}})
    elif $name == "TaskUpdate" then
      .pending = (.pending + {($id): {op: "update",
                                      task: safe($c.input.taskId // ""),
                                      status: (if ($c.input.status | type) == "string" then $c.input.status else null end),
                                      subject: (if ($c.input.subject | type) == "string" then safe_brief($c.input.subject; 120) else null end)}})
    elif $name == "TaskList" or $name == "TaskGet" then
      .pending = (.pending + {($id): {op: "list"}})
    else
      append("[tool] \(safe_brief($name; 40)) \(tool_args($c.input; .cwd))")
    end;

# claude_task_apply: apply a TaskCreate / TaskUpdate / TaskList outcome once
# its tool_result arrives. $tur is the event-level tool_use_result (may be
# null on older builds); $content is the tool_result text.
def claude_task_id_from_text($content):
  (as_text($content) | capture("Task #(?<id>[0-9]+)") | .id) // null;

def claude_task_create($op; $tur; $content):
  (if ($tur.task.id | type) == "string" or ($tur.task.id | type) == "number"
     then ($tur.task.id | tostring)
   else claude_task_id_from_text($content) end) as $tid
  | (if ($tur.task.subject | type) == "string" and ($tur.task.subject | length) > 0
       then safe_brief($tur.task.subject; 120) else $op.subject end) as $subject
  | if $tid == null or $subject == "" then .
    elif (.task_ids[$tid] // null) != null then .
    else
      (.todos | length) as $idx
      | .task_ids = (.task_ids + {($tid): $idx})
      | set_todos(.todos + [{text: $subject, status: "pending"}])
    end;

def claude_task_update($op; $tur):
  (if ($tur.taskId | type) == "string" or ($tur.taskId | type) == "number"
     then ($tur.taskId | tostring) else $op.task end) as $tid
  | (if ($tur.statusChange.to | type) == "string" then $tur.statusChange.to else $op.status end) as $status
  | if $tid == "" then .
    else
      (.task_ids[$tid] // null) as $idx
      | if $idx == null then
          # An item created before this stream started (resumed session).
          (.todos | length) as $new
          | .task_ids = (.task_ids + {($tid): $new})
          | set_todos(.todos + [{text: ($op.subject // "task #\($tid)"),
                                 status: (if $status == null then "pending" else todo_status($status) end)}])
        else
          (.todos[$idx]) as $cur
          | ($cur
             | (if $status != null then .status = todo_status($status) else . end)
             | (if ($op.subject // null) != null then .text = $op.subject else . end)) as $next
          | set_todos(.todos | .[$idx] = $next)
        end
    end;

def claude_task_list($tur):
  if ($tur.tasks | type) != "array" then .
  else
    ($tur.tasks | map(select(type == "object"))) as $ts
    | reduce ($ts | to_entries)[] as $e (
        .task_ids = {};
        .task_ids = (.task_ids + {(($e.value.id // $e.key) | tostring): $e.key}))
    | set_todos($ts | map(todo_item(.)))
  end;

def claude_tool_result($c; $tur):
  ($c.tool_use_id // "") as $id
  | (.tools[$id] // "tool") as $name
  | (.pending[$id] // null) as $op
  | if $op != null then
      .pending = (.pending | del(.[$id]))
      | if ($c.is_error // false) then
          append("[error] \($name): \(tool_result($c.content))")
        elif $op.op == "create" then claude_task_create($op; $tur; $c.content)
        elif $op.op == "update" then claude_task_update($op; $tur)
        elif $op.op == "list" then claude_task_list($tur)
        else . end
    elif $name == "TodoWrite" then
      (if ($c.is_error // false) then append("[error] TodoWrite: \(tool_result($c.content))") else . end)
    elif ($c.is_error // false) then
      append("[error] \($name): \(tool_result($c.content))")
    else
      append("[done] \($name)")
    end;

def claude_block($c):
  ($c.type // "?") as $ct
  | if $ct == "text" then
      (($c.text // "") | clean) as $txt
      | claude_text_block($txt)
      | (if (($c.text // "") | type) == "string" and $c.text != "" then .last_text = $c.text else . end)
    elif $ct == "tool_use" then claude_tool_use($c)
    elif $ct == "thinking" then
      (($c.thinking // "") | clean) as $txt
      | if ($txt | gsub("^\\s+|\\s+$"; "") | length) > 0
        then append("[think]") | append($txt | sub("\n+$"; ""))
        else . end
    elif $ct == "redacted_thinking" then .
    else append("[note] assistant content: \(safe_brief($ct; 40))")
    end;

def result_closer($ev):
  "[run] result \(safe_brief($ev.subtype // "unknown"; 40))"
  + (if ($ev.duration_ms | type) == "number"
      then " (\($ev.duration_ms)ms, \($ev.num_turns // "?") turns"
           + (if ($ev.permission_denials | type) == "array" and ($ev.permission_denials | length) > 0
              then ", \($ev.permission_denials | length) denied" else "" end)
           + ")"
     else "" end);

def claude_system($ev):
  ($ev.subtype // "") as $st
  | if $st == "init" then
      (if ($ev.cwd | type) == "string" then .cwd = $ev.cwd else . end)
      | emit("[run] claude \(safe_brief($ev.model // "?"; 40)) session \(safe($ev.session_id // "?") | .[0:8])")
    elif $st == "can_use_tool" then
      emit("[wait] permission: \(safe_brief($ev.tool_name // $ev.tool // "request"; 60))")
    elif $st == "task_summary" then
      (safe_brief($ev.detail // ""; 120)) as $d
      | if $d == "" then . else emit("[step] \($d)") end
    elif $st == "post_turn_summary" then
      (safe_brief($ev.status_detail // ""; 200)) as $d
      | (safe_brief($ev.needs_action // ""; 200)) as $need
      | (if $d == "" then . else append("[note] summary: \($d)") end)
      | (if $need == "" then . else append("[warn] needs action: \($need)") end)
    elif $st == "task_started" then
      emit("[note] subagent \(safe_brief($ev.subagent_type // "task"; 30)) started: \(safe_brief($ev.description // ""; 80))")
    elif $st == "task_notification" then
      emit("[note] subagent \(safe_brief($ev.status // "ended"; 20)): \(safe_brief($ev.summary // $ev.description // ""; 100))")
    elif $st == "compact_boundary" then
      emit("[note] context compacted (\(safe_brief($ev.compact_metadata.trigger // "auto"; 20)))")
    elif (claude_system_quiet | index($st)) then .
    else . end;

def claude_event($ev):
  ($ev.type // "?") as $t
  | if $t == "system" then claude_system($ev)
    elif $t == "control_request" then
      if ($ev.request.subtype // "") == "can_use_tool" then
        (safe_brief($ev.request.decision_reason // ""; 80)) as $why
        | emit("[wait] permission: \(safe_brief($ev.request.tool_name // "tool"; 40)) \(tool_args($ev.request.input; .cwd))"
               + (if $why == "" then "" else " (\($why))" end))
      else . end
    elif $t == "assistant" then
      ($ev.message.content // "") as $content
      | (if ($content | type) == "string" then [{type: "text", text: $content}]
         elif ($content | type) == "array" then $content
         else [] end) as $blocks
      | reduce $blocks[] as $c (.; claude_block($c))
    elif $t == "user" then
      ($ev.message.content // "") as $content
      | (if ($content | type) == "array" then $content else [] end) as $blocks
      | ([$blocks[] | select((.type // "") == "tool_result")] | length) as $nres
      | (if $nres == 1 and ($ev.tool_use_result | type) == "object" then $ev.tool_use_result else {} end) as $tur
      | reduce $blocks[] as $c (.;
          if ($c.type // "") == "tool_result" then claude_tool_result($c; $tur) else . end)
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

# ---------------------------------------------------------------------- pi --
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
      (safe($ev.toolCallId // "")) as $id
      | (if is_plan_tool($ev.toolName) then plan_items($ev.args) else null end) as $items
      | if $items != null then
          .plan_ids = (.plan_ids + {($id): true})
          | .act = "emit" | .out = (if .mid then "\n" else "" end) | .mid = false
          | set_todos($items)
        else
          emit("[tool] \(safe_brief($ev.toolName // "tool"; 40)) \(tool_args($ev.args))")
        end
    elif $t == "tool_execution_end" then
      (safe($ev.toolCallId // "")) as $id
      | (if ($ev.isError == true)
          then emit("[error] \(safe_brief($ev.toolName // "tool"; 40)): \(tool_result($ev.result))")
          elif (.plan_ids[$id] // false) then .plan_ids = (.plan_ids | del(.[$id]))
          else emit("[done] \(safe_brief($ev.toolName // "tool"; 40))") end)
    elif $t == "auto_retry_start" then
      emit("[wait] retry \(safe($ev.attempt))/\(safe($ev.maxAttempts)) in \(safe($ev.delayMs))ms: \(safe_brief($ev.errorMessage // ""; 120))")
    elif $t == "compaction_start" then
      emit("[wait] compacting context (\(safe_brief($ev.reason // "unknown"; 40)))")
    elif $t == "compaction_end" then
      (if ($ev.aborted // false) then emit("[error] compaction aborted") else emit("[note] context compacted") end)
    elif $t == "agent_end" then
      (if ($ev.willRetry // false) then emit("[wait] retrying") else . end)
    elif $t == "summarization_retry_scheduled" then
      emit("[wait] summarization retry \(safe($ev.attempt))/\(safe($ev.maxAttempts)) in \(safe($ev.delayMs))ms: \(safe_brief($ev.errorMessage // ""; 120))")
    elif (pi_quiet | index($t)) then
      .
    else
      emit("[note] unhandled pi event type: \(safe_brief($t; 40))")
    end;

# ------------------------------------------------------------------ cursor --
# *ToolCall nested object names the tool (readToolCall -> read).
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

def cursor_plan_items($tc):
  cursor_tool_key($tc) as $k
  | if $k == null then null
    elif is_plan_tool($k) then plan_items($tc[$k].args // {})
    else null end;

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
      | (safe($ev.call_id // $tc.toolCallId // "")) as $id
      | if ($ev.subtype // "") == "started" then
          cursor_plan_items($tc) as $items
          | if $items != null then
              .plan_ids = (.plan_ids + {($id): true})
              | .act = "emit" | .out = (if .mid then "\n" else "" end) | .mid = false
              | set_todos($items)
            else emit("[tool] \($name) \(cursor_tool_args($tc))") end
        elif ($ev.subtype // "") == "completed" then
          if cursor_tool_ok($tc) then
            (if (.plan_ids[$id] // false) then .plan_ids = (.plan_ids | del(.[$id]))
             else emit("[done] \($name)") end)
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

# -------------------------------------------------------------------- grok --
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
      | (if is_plan_tool($ev.toolName // $ev.title) then plan_items($ev.rawInput // {}) else null end) as $items
      | if $items != null then
          .plan_ids = (.plan_ids + {($id): true})
          | .act = "emit" | .out = (if .mid then "\n" else "" end) | .mid = false
          | set_todos($items)
        else emit("[tool] \($name) \(tool_args($ev.rawInput // {}))") end
    elif $t == "tool_call_update" then
      (if ($ev.toolCallId | type) == "string" then $ev.toolCallId else "" end) as $id
      | (.tools[$id] // "tool") as $name
      | if ($ev.status // "") == "completed" then
          (if (.plan_ids[$id] // false) then .plan_ids = (.plan_ids | del(.[$id]))
           else emit("[done] \($name)") end)
        elif ($ev.status // "") == "failed" then
          emit("[error] \($name): \(tool_result($ev.rawOutput // $ev.content))")
        else .
        end
    elif $t == "end" then
      emit("[run] result \(safe_brief($ev.stopReason // "end"; 40))")
    elif $t == "plan" then
      # Grok's streaming-json mirrors ACP session updates; a plan carries
      # entries like ACP's. Not observed in a real stream.
      (acp_plan_entries($ev.entries) // []) as $items
      | if ($items | length) > 0 then set_todos($items) else . end
    elif (grok_quiet | index($t)) then
      .
    else
      emit("[note] unhandled grok event type: \(safe_brief($t; 40))")
    end;

# --------------------------------------------------------------------- acp --
# Agent Client Protocol: newline-delimited JSON-RPC 2.0 on the agent's
# stdout. Protocol 2 is the primary target (the bridge offers it by
# default); protocol 1 is still handled for agents that answer initialize
# with 1. Shapes come from the published @agentclientprotocol/sdk 1.7.0
# schemas (schema/v2/schema.unstable.json for protocol 2, schema/schema.json
# for protocol 1), read in full; no real ACP agent was run here. Both are
# handled by the same code because they differ in kinds, not in framing:
#
#   notification  {"method":"session/update","params":{"sessionId","update":{"sessionUpdate":KIND,...}}}
#     v2 kinds    agent_message_chunk, agent_message {messageId, content[]},
#                 agent_thought_chunk, agent_thought, tool_call_update (no
#                 separate tool_call: the first update for an id is the start),
#                 state_update {state: running|idle|requires_action|unknown,
#                 idle: stopReason?, usage? {totalTokens,inputTokens,outputTokens}},
#                 plan_update {plan:{type:items,planId,entries}|{type:markdown,content}|{type:file,uri}},
#                 plan_removed {planId}, notice {severity, title},
#                 compaction_update {compactionId,status,summary[],error},
#                 subagent_update {sessionId, title, state: StateUpdate object},
#                 usage_update {used,size,cost}, session_info_update,
#                 terminal_*, session_message*, user_message*
#     v1 kinds    tool_call, plan {entries}, current_mode_update
#   request       {"id":N,"method":"session/request_permission","params":{...}}
#                 v2 params.title plus subject {type:tool_call, toolCall} or
#                 {type:command, command, cwd}; v1 params.toolCall.title.
#                 A description field is not in either schema but is shown
#                 when present.
#   response      {"id":N,"result":{...}}: initialize {protocolVersion,
#                 info (v2) | agentInfo (v1)}, session/new {sessionId},
#                 session/prompt {messageId} (v2: the stop reason then
#                 arrives in the idle state_update) or {stopReason} (v1)
#
# Responses carry no method, so the client's own requests are remembered
# when they are in the stream (a dispatcher that logs both directions) and
# recognised by their result keys otherwise.

def acp_quiet_updates:
  ["user_message_chunk", "user_message", "available_commands_update",
   "current_mode_update", "config_option_update", "session_info_update",
   "usage_update", "tool_call_content_chunk", "terminal_update",
   "terminal_output_chunk", "compaction_summary_chunk", "session_message",
   "session_message_chunk"];

def acp_text($c):
  if ($c | type) == "array" then as_text($c)
  elif ($c | type) == "object" then
    (if ($c.type // "") == "text" then ($c.text // "")
     elif ($c.type // "") == "image" then "[image]"
     elif ($c.type // "") == "resource_link" then ($c.uri // $c.name // "[resource]")
     elif ($c.type // "") == "resource" then "[resource]"
     else as_text($c) end)
  else as_text($c) end
  | if type == "string" then . else "" end;

def acp_tool_label($u):
  (safe_brief($u.title // ""; 80)) as $title
  | if $title != "" then $title
    else "\(safe_brief($u.name // $u.kind // "tool"; 40)) \(tool_args($u.rawInput // {}))" end;

def acp_tool($u):
  (safe($u.toolCallId // "")) as $id
  | ($u.status // "") as $status
  | if $id != "" and (.tools[$id] // null) == null then
      # First sight of this call: that is its start, whatever the status.
      (acp_tool_label($u)) as $label
      | .tools = (.tools + {($id): ($label | .[0:40])})
      | append("[tool] \($label)")
      | (if $status == "completed" then append("[done] \(.tools[$id])")
         elif $status == "failed" then append("[error] \(.tools[$id]): \(tool_result($u.rawOutput // $u.content))")
         elif $status == "cancelled" then append("[error] \(.tools[$id]): cancelled")
         else . end)
    else
      (.tools[$id] // "tool") as $name
      | if $status == "completed" then append("[done] \($name)")
        elif $status == "failed" then append("[error] \($name): \(tool_result($u.rawOutput // $u.content))")
        elif $status == "cancelled" then append("[error] \($name): cancelled")
        else . end
    end;

def acp_update($u):
  ($u.sessionUpdate // "") as $k
  # v2 chunks and whole messages carry a messageId: a whole message whose
  # id already arrived as chunks is not repeated, and any other whole
  # message is shown. Without ids (protocol 1) the turn-wide flags decide.
  | (safe($u.messageId // "")) as $mid
  | if $k == "agent_message_chunk" then
      (acp_text($u.content) | clean) as $d
      | if $d == "" then .
        else .saw_delta = true | .last_text = (.last_text + $d)
             | (if $mid != "" then ._acp_streamed = ((.["_acp_streamed"] // {}) + {($mid): true}) else . end)
             | raw_after_think($d) end
    elif $k == "agent_message" then
      (acp_text($u.content) | clean) as $t
      | if $mid != "" and ((.["_acp_streamed"] // {})[$mid] // false) then
          .saw_delta = false | ._acp_streamed = (.["_acp_streamed"] | del(.[$mid]))
        elif $mid == "" and .saw_delta then .saw_delta = false
        elif ($t | gsub("^\\s+|\\s+$"; "") | length) == 0 then .
        else .saw_delta = false | .last_text = $t | raw_after_think($t) end
    elif $k == "agent_thought_chunk" then
      (acp_text($u.content) | clean) as $d
      | (if $mid != "" and $d != "" then ._acp_streamed = ((.["_acp_streamed"] // {}) + {($mid): true}) else . end)
      | think_delta($d)
    elif $k == "agent_thought" then
      (acp_text($u.content) | clean) as $t
      | if $mid != "" and ((.["_acp_streamed"] // {})[$mid] // false) then
          ._acp_streamed = (.["_acp_streamed"] | del(.[$mid]))
        elif $mid == "" and .thinking then .thinking = false
        elif ($t | gsub("^\\s+|\\s+$"; "") | length) == 0 then .
        else emit("[think]") | .out = (.out + ($t | sub("\n+$"; "")) + "\n") | .thinking = false end
    elif $k == "tool_call" or $k == "tool_call_update" then
      acp_tool($u)
    elif $k == "plan" then
      (acp_plan_entries($u.entries) // []) as $items
      | if ($items | length) > 0 then set_todos($items) else . end
    elif $k == "plan_update" then
      ($u.plan // {}) as $p
      | if ($p.entries | type) == "array" then
          (acp_plan_entries($p.entries) // []) as $items
          | if ($items | length) > 0 then set_todos($items) else . end
        elif ($p.type // "") == "markdown" then
          emit("[note] plan (markdown): \(safe_brief($p.content // ""; 120))")
        elif ($p.type // "") == "file" then
          emit("[note] plan file: \(safe_brief($p.uri // ""; 120))")
        else . end
    elif $k == "plan_removed" then
      .todos = [] | emit("[note] plan removed")
    elif $k == "state_update" then
      ($u.state // "") as $s
      | if $s == "requires_action" then emit("[wait] input: the agent needs your action")
        elif $s == "idle" and ($u.stopReason | type) == "string" then
          # v2 idle carries the turn's usage; the token total rides on the
          # result line so the state tracker can count it.
          (($u.usage // {}).totalTokens // null) as $tok
          | emit("[run] result \(safe_brief($u.stopReason; 40))"
                 + (if ($tok | type) == "number" and $tok >= 0 then " (\($tok | floor) tokens)" else "" end))
        else . end
    elif $k == "notice" then
      (safe_brief($u.title // ""; 80)) as $title
      | (safe_brief($u.description // ""; 160)) as $desc
      | ($title + (if $title != "" and $desc != "" then ": " else "" end) + $desc) as $msg
      | if $msg == "" then .
        elif ($u.severity // "") == "error" then emit("[error] \($msg)")
        elif ($u.severity // "") == "warning" then emit("[warn] \($msg)")
        else emit("[note] \($msg)") end
    elif $k == "compaction_update" then
      ($u.status // "") as $s
      | if $s == "in_progress" then emit("[wait] compacting context")
        elif $s == "completed" then emit("[note] context compacted")
        elif $s == "failed" then emit("[error] compaction failed: \(safe_brief($u.error // ""; 120))")
        elif $s == "cancelled" then emit("[note] compaction cancelled")
        else . end
    elif $k == "subagent_update" then
      # v2 state is a StateUpdate object ({state: running|idle|...}); a bare
      # string is accepted too.
      (if ($u.state | type) == "object" then $u.state.state else $u.state end) as $st
      | emit("[note] subagent \(safe_brief($st // "update"; 20)): \(safe_brief($u.title // $u.description // ""; 80))")
    elif (acp_quiet_updates | index($k)) then .
    else emit("[note] unhandled acp update: \(safe_brief($k; 40))")
    end;

def acp_rpc_id($ev):
  if ($ev.id | type) == "string" or ($ev.id | type) == "number" then ($ev.id | tostring) else "" end;

def acp_event($ev):
  ($ev.method // "") as $m
  | acp_rpc_id($ev) as $id
  | if $m == "session/update" then
      acp_update(if ($ev.params.update | type) == "object" then $ev.params.update else {} end)
    elif $m == "session/request_permission" then
      ($ev.params // {}) as $p
      | (if ($p.subject | type) == "object" then $p.subject else {} end) as $subj
      | ($p.toolCall // $subj.toolCall // {}) as $tc
      | ([$p.title, $tc.title] | map(safe_brief(.; 80)) | map(select(. != "")) | .[0] // "") as $title
      | (safe_brief($p.description // (if ($subj.type // "") == "command" then $subj.command else null end) // ""; 100)) as $desc
      | (if $title != "" then $title
         else "\(safe_brief($tc.name // $tc.kind // $subj.type // "request"; 40)) \(tool_args($tc.rawInput // {}))" end) as $what
      | emit("[wait] permission: \($what)" + (if $desc == "" then "" else " (\($desc))" end))
    elif $m == "session/cancel" then
      emit("[note] cancel requested")
    elif $m != "" and $id != "" then
      # A request: the client's own (logged by a dispatcher) or the agent's
      # (fs/*, terminal/*, elicitation/*). Remember the method for its reply.
      ._rpc = ((.["_rpc"] // {}) + {($id): $m})
    elif $m != "" then .
    elif ($ev | has("result")) then
      ($ev.result // {}) as $r
      | ((.["_rpc"] // {})[$id] // "") as $method
      | if $method == "initialize" or (($r | type) == "object" and ($r | has("protocolVersion"))) then
          (safe_brief($r.info.name // $r.agentInfo.name // "agent"; 40)) as $name
          | (safe_brief($r.info.version // $r.agentInfo.version // ""; 20)) as $ver
          | ._acp_agent = $name
          | emit("[note] acp agent \($name)\(if $ver == "" then "" else " " + $ver end) (protocol \(safe($r.protocolVersion // "?")))")
        elif $method == "session/new" or (($r | type) == "object" and ($r | has("sessionId")) and (($r | has("stopReason")) | not)) then
          emit("[run] acp \(.["_acp_agent"] // "agent") session \(safe($r.sessionId // "?") | .[0:8])")
        elif ($r | type) == "object" and ($r.stopReason | type) == "string" then
          emit("[run] result \(safe_brief($r.stopReason; 40))")
        else . end
    elif ($ev | has("error")) then
      emit("[error] rpc \(safe($ev.error.code // "")): \(safe_brief($ev.error.message // "error"; 160))")
    else
      emit("[note] unhandled acp message")
    end;

def handle($ev):
  if $fmt == "pi-json" then pi_event($ev)
  elif $fmt == "claude-json" then claude_event($ev)
  elif $fmt == "cursor-json" then cursor_event($ev)
  elif $fmt == "grok-json" then grok_event($ev)
  elif $fmt == "acp-json" then acp_event($ev)
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
    elif .act == "emit" and (.out // "") != "" then .out
    elif .act == "warn" then
      if .we == "invalid event shape" or .we == "non-object JSON event" then
        "[warn] skipped event near input line \(.wl): \(.we)\n"
      else
        "[warn] malformed JSON event near input line \(.wl), skipped: \(.we)\n"
      end
    else empty end
  )
