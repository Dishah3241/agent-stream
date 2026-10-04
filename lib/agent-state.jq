# agent-state.jq: the run state machine behind agent_state_track.
# Reads activity protocol lines (the output of agent_output_render, see
# docs/design.md section 5) one raw line at a time and emits one compact
# JSON snapshot of the run state whenever it changes. Inputs:
#
#   $seed  object merged over the initial state: id, agent, model_requested,
#          project {name, dir, branch}, task, started_at, record {...}
#   $live  true: emit a snapshot after every label line and at most once a
#          second for plain text; false: emit only the final state at EOF.
#
# Every string here already passed the renderer's sanitizer. This program
# never reads events and never writes files; the Bash side does the
# atomic write. Every capture is guarded with "// null": a non-matching
# capture yields nothing, and an empty update would reset the state.

def now_iso: now | todate;

def init_state($seed):
  { schema: "agent-stream/state/1",
    id: null, status: "starting",
    agent: null, model: null, model_requested: null, session: null,
    project: {name: null, dir: null, branch: null},
    task: null,
    started_at: now_iso, updated_at: now_iso, ended_at: null, elapsed_s: 0,
    activity: {kind: "idle", text: null, since: now_iso},
    step: null,
    waiting: null,
    todos: [],
    todo_counts: {total: 0, done: 0, active: 0, pending: 0, dropped: 0},
    counts: {tools: 0, tool_errors: 0, errors: 0, warnings: 0, notes: 0,
             waits: 0, text_lines: 0, todo_updates: 0, turns: null, tokens: null},
    last_text: null, last_error: null, last_warning: null,
    result: null,
    outcome: null,
    record: {} }
  * (if ($seed | type) == "object" then $seed else {} end)
  | ._thinking = false | ._open = 0 | ._last_emit = 0 | ._dirty = true
  | ._prev_todo = false;

def touch: .updated_at = now_iso
  | if ._el_fixed == true then .
    else .elapsed_s = ((now - ((.started_at | fromdate?) // now)) | floor) end;

def activity($kind; $text):
  .activity = {kind: $kind, text: $text, since: now_iso};

def clear_wait: if .waiting != null then .waiting = null | .status = "running" else . end;

def recount_todos:
  .todo_counts = {
    total: (.todos | length),
    done: ([.todos[] | select(.status == "done")] | length),
    active: ([.todos[] | select(.status == "active")] | length),
    pending: ([.todos[] | select(.status == "pending")] | length),
    dropped: ([.todos[] | select(.status == "dropped")] | length) };

def trim($n): if type == "string" and length > $n then .[0:$n] + "..." else . end;

# [todo] I/N STATUS text
def apply_todo($rest):
  (($rest | capture("^(?<i>[0-9]+)/(?<n>[0-9]+) (?<status>pending|active|done|dropped)(?: (?<text>.*))?$")) // null) as $m
  | if $m == null then .
    else
      ($m.i | tonumber) as $i
      | ($m.n | tonumber) as $n
      | ($m.text // "") as $text
      | if $i < 1 or $i > $n or $n > 500 then .
        else
          # Resize to N, keeping what is known, then set item I.
          .todos as $old
          | .todos = [range(0; $n) | ($old[.] // {text: "", status: "pending"})
                      | {text: .text, status: .status}]
          | .todos[$i - 1] = {text: $text, status: $m.status}
          | .todos = [.todos | to_entries[] | .value + {n: (.key + 1)}]
          | .counts.todo_updates += 1
          | recount_todos
        end
    end;

# [end] OUTCOME exit N elapsed S record PATH
def apply_end($rest):
  (($rest | capture("^(?<kind>[a-z_]+) exit (?<exit>[0-9]+)(?: elapsed (?<el>[0-9]+)s)?(?: record (?<rec>.*))?$")) // null) as $m
  | .status = "ended" | .ended_at = now_iso | .waiting = null
  | if $m == null then .outcome = ((.outcome // {}) + {kind: "unknown", detail: $rest})
    else
      .outcome = ((.outcome // {}) + {kind: $m.kind, exit: ($m.exit | tonumber),
                                      detail: ((.result // {}).detail // null)})
      | (if $m.el != null then .elapsed_s = ($m.el | tonumber) | ._el_fixed = true else . end)
    end;

def apply_run($rest):
  if ($rest | startswith("result ")) then
    ($rest | ltrimstr("result ")) as $r
    | ($r | capture("^(?<sub>[^ ]+)(?: \\((?<ms>[0-9]+)ms, (?<turns>[0-9?]+) turns.*\\))?") // {sub: $r}) as $m
    | .result = {subtype: $m.sub, detail: $r,
                 kind: (if $m.sub == "success" or $m.sub == "end_turn" or $m.sub == "end" or $m.sub == "stop" then "success"
                        elif ($m.sub | test("cancel|abort|interrupt")) then "cancelled"
                        else "error" end)}
    | (if ($m.turns // "?") != "?" then .counts.turns = ($m.turns | tonumber) else . end)
    | (($r | capture("[(, ](?<tok>[0-9]+) tokens[,)]") // {}).tok // null) as $tok
    | (if $tok != null then .counts.tokens = ($tok | tonumber) else . end)
    | (if .status != "ended" then .status = "ended" | .ended_at = now_iso end)
    | .waiting = null
    | activity("done"; "result \($m.sub)")
    | .outcome = ((.outcome // {}) + {kind: .result.kind, detail: $r})
  else
    ($rest | capture("^(?<agent>[^ ]+)(?: (?<model>[^ ]+))?(?: session (?<sid>[^ ]+))?") // {}) as $m
    | (if .agent == null and $m.agent != null then .agent = $m.agent else . end)
    | (if $m.model != null then .model = $m.model else . end)
    | (if $m.sid != null then .session = $m.sid else . end)
    | (if .status == "starting" then .status = "running" else . end)
  end;

def apply_line($line):
  (($line | capture("^\\[(?<label>run|tool|done|error|warn|note|think|wait|todo|step|end)\\](?: (?<rest>.*)|)$")) // null) as $m
  | if $m == null then
      # Plain text: assistant prose, or reasoning after a [think] line.
      if ($line | gsub("^\\s+|\\s+$"; "") | length) == 0 then .
      elif ._thinking then ._dirty = false
      else
        .counts.text_lines += 1
        | .last_text = ($line | trim(240))
        | clear_wait
        | (if .status == "starting" then .status = "running" else . end)
        | activity("text"; ($line | trim(120)))
      end
    else
      ($m.rest // "") as $rest
      | ._thinking = ($m.label == "think")
      | (if .status == "starting" and $m.label != "end" then .status = "running" else . end)
      | if $m.label == "tool" then
          clear_wait | .counts.tools += 1 | ._open += 1
          | activity("tool"; ($rest | trim(120)))
        elif $m.label == "done" then
          clear_wait | ._open = ([._open - 1, 0] | max)
          | activity("done"; ($rest | trim(120)))
        elif $m.label == "error" then
          clear_wait | .counts.errors += 1 | .last_error = ($rest | trim(240))
          | (if ._open > 0 then .counts.tool_errors += 1 | ._open -= 1 else . end)
          | activity("error"; ($rest | trim(120)))
        elif $m.label == "warn" then
          .counts.warnings += 1 | .last_warning = ($rest | trim(240))
        elif $m.label == "note" then
          clear_wait
          | if ($rest | startswith("summary: ")) then
              .outcome = ((.outcome // {}) + {summary: ($rest | ltrimstr("summary: ") | trim(240))})
            elif $rest == "plan removed" then .todos = [] | recount_todos
            else .counts.notes += 1 end
        elif $m.label == "think" then
          clear_wait | activity("think"; null)
        elif $m.label == "wait" then
          ($rest | capture("^(?<kind>[a-z]+):? ?(?<text>.*)$") // {kind: "wait", text: $rest}) as $w
          | .counts.waits += 1
          | .waiting = {kind: $w.kind, text: ($w.text | trim(200)), since: now_iso}
          | .status = "waiting"
          | activity("wait"; ($rest | trim(120)))
        elif $m.label == "todo" then clear_wait | apply_todo($rest)
        elif $m.label == "step" then clear_wait | .step = ($rest | trim(160))
        elif $m.label == "run" then apply_run($rest)
        elif $m.label == "end" then apply_end($rest)
        else . end
    end
  | touch;

def snapshot:
  del(._thinking, ._open, ._last_emit, ._dirty, ._prev_todo, ._el_fixed, ._label, ._final);

init_state($seed)
| foreach (inputs, null) as $line (
    .;
    if $line == null then ._final = true
    else
      ._dirty = true
      | apply_line($line)
      | ._label = ($line | test("^\\[(run|tool|done|error|warn|note|wait|todo|step|end)\\]"))
    end;
    if ._final == true then snapshot
    elif $live != true then empty
    elif ._dirty != true then empty
    elif ._label or (now - ._last_emit) >= 1 then (._last_emit = now) | snapshot
    else empty end
  )
