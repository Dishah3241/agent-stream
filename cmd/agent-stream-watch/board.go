package main

// The combined board: the fleet view over every machine named in
// board.json, read over SSH (docs/spec-themes.md section 7). Each machine
// is polled in the background through one shared OpenSSH connection; a
// poll runs one small POSIX shell command that prints the records whose
// state.json changed since the last poll. The run view reads display.txt
// with `tail -c +OFFSET`. Nothing is installed on, or written to, any
// machine.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Source is where the runs come from: local record roots or a board.
type Source interface {
	Refresh(prev []*Run, now time.Time) []*Run
	Tail(dir string, offset int64, partial string) ([]string, int64, string, bool, error)
	Describe() string
}

type localSource struct{ roots []string }

func (s localSource) Refresh(prev []*Run, now time.Time) []*Run { return Refresh(prev, s.roots, now) }
func (s localSource) Tail(dir string, offset int64, partial string) ([]string, int64, string, bool, error) {
	return Tail(dir, offset, partial)
}
func (s localSource) Describe() string { return tildeList(s.roots) }

// Machine is one entry of board.json.
type Machine struct {
	Name  string `json:"name"`
	SSH   string `json:"ssh"`   // the ssh destination; defaults to Name
	Root  string `json:"root"`  // the record root there; defaults to ~/.agent-stream/runs
	Local bool   `json:"local"` // read this machine's root without ssh
}

// Signal is a machine row that stands in for its runs: dialing before the
// first answer, no signal after a failed poll.
type Signal struct {
	Machine  string
	Answered time.Time // last good poll, zero when never
	Err      string    // empty while dialing
}

var machineName = regexp.MustCompile(`^[A-Za-z0-9._-]{1,24}$`)

// LoadBoard reads and checks board.json.
func LoadBoard(path string) ([]Machine, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg struct {
		Machines []Machine `json:"machines"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if len(cfg.Machines) == 0 {
		return nil, fmt.Errorf("%s: no machines", path)
	}
	seen := map[string]bool{}
	for i := range cfg.Machines {
		m := &cfg.Machines[i]
		if !machineName.MatchString(m.Name) {
			return nil, fmt.Errorf("%s: machine name %q: use letters, digits, '.', '_' or '-'", path, m.Name)
		}
		if seen[m.Name] {
			return nil, fmt.Errorf("%s: machine %q named twice", path, m.Name)
		}
		seen[m.Name] = true
		if m.SSH == "" {
			m.SSH = m.Name
		}
		// A destination that starts with '-' would be read as an ssh option.
		if strings.HasPrefix(m.SSH, "-") || strings.ContainsAny(m.SSH, " \t\n") {
			return nil, fmt.Errorf("%s: machine %q: bad ssh destination %q", path, m.Name, m.SSH)
		}
		if m.Root == "" {
			m.Root = "~/.agent-stream/runs"
		}
	}
	return cfg.Machines, nil
}

// The poll script. $1 is the root, $2 the remote time of the last poll.
// It prints "@ok NOW ROOT", then "@rec ID MTIME" for every record with a
// state.json, followed by "@state ID BYTES" and the file for those changed
// since $2. Run with LC_ALL=C so ${#s} counts bytes.
const pollScript = `root=$1; since=$2
case $root in "~") root=$HOME ;; "~/"*) root=$HOME/${root#"~/"} ;; esac
cd "$root" 2>/dev/null || { printf '@noroot %s\n' "$(date +%s)"; exit 0; }
printf '@ok %s %s\n' "$(date +%s)" "$(pwd)"
for d in */; do
  d=${d%/}
  case $d in *[!A-Za-z0-9._-]*) continue ;; esac
  f=$d/state.json
  [ -f "$f" ] && [ ! -h "$f" ] || continue
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || continue
  printf '@rec %s %s\n' "$d" "$m"
  [ "$m" -ge "$since" ] || continue
  s=$(cat "$f") || continue
  printf '@state %s %s\n%s\n' "$d" "${#s}" "$s"
done`

// The tail script: $1 the record, $2 the offset. Prints "@size BYTES", then
// up to a megabyte from the offset; "@none" when there is no display.txt.
const tailScript = `f=$1/display.txt
[ -f "$f" ] && [ ! -h "$f" ] || { echo @none; exit 0; }
s=$(wc -c <"$f"); s=$((s + 0))
printf '@size %s\n' "$s"
[ "$s" -gt "$2" ] || exit 0
tail -c +$(($2 + 1)) "$f" | head -c 1048576`

const tailChunk = 1 << 20

type machineState struct {
	busy     bool
	polled   time.Time // when the last poll finished, local clock
	answered time.Time // when the last good poll finished
	err      string
	since    int64         // remote clock for the next poll
	skew     time.Duration // local clock minus remote clock
	root     string        // the root as the machine resolved it
	runs     map[string]*Run
}

type tailJob struct {
	from  int64
	reset bool
	done  bool
	data  []byte
	size  int64
	err   error
}

// Board is the Source for a board.json.
type Board struct {
	Machines []Machine
	SSH      []string      // the ssh command and its own arguments
	Every    time.Duration // how often each machine is polled
	Timeout  time.Duration // how long one remote command may take
	ctl      string        // the ControlPath directory, "" for none

	mu    sync.Mutex
	state []*machineState
	tails map[string]*tailJob
}

// NewBoard prepares a board. The ssh command is $AGENT_STREAM_SSH (split on
// spaces) or ssh; the connection is shared through a ControlMaster socket
// under the user's cache directory, the one thing the board creates, and
// only on this machine.
func NewBoard(machines []Machine) *Board {
	b := &Board{Machines: machines, SSH: []string{"ssh"}, Every: 2 * time.Second, Timeout: 20 * time.Second,
		tails: map[string]*tailJob{}}
	if v := strings.Fields(os.Getenv("AGENT_STREAM_SSH")); len(v) > 0 {
		b.SSH = v
	}
	if d, err := os.UserCacheDir(); err == nil {
		d = filepath.Join(d, "agent-stream", "ssh")
		if os.MkdirAll(d, 0o700) == nil {
			b.ctl = d
		}
	}
	for range machines {
		b.state = append(b.state, &machineState{runs: map[string]*Run{}})
	}
	return b
}

func (b *Board) Describe() string {
	names := make([]string, len(b.Machines))
	for i, m := range b.Machines {
		names[i] = m.Name
	}
	return strings.Join(names, ", ")
}

// shellQuote quotes s for a POSIX shell.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// command runs script with args on machine m and returns its stdout.
func (b *Board) command(m Machine, script string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), b.Timeout)
	defer cancel()
	var cmd *exec.Cmd
	if m.Local {
		cmd = exec.CommandContext(ctx, "sh", append([]string{"-c", script, "sh"}, args...)...)
		cmd.Env = append(os.Environ(), "LC_ALL=C")
	} else {
		remote := "LC_ALL=C sh -c " + shellQuote(script) + " sh"
		for _, a := range args {
			remote += " " + shellQuote(a)
		}
		argv := append([]string{}, b.SSH[1:]...)
		argv = append(argv, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5")
		if b.ctl != "" {
			argv = append(argv, "-o", "ControlMaster=auto", "-o", "ControlPath="+filepath.Join(b.ctl, "%C"),
				"-o", "ControlPersist=60")
		}
		argv = append(argv, m.SSH, remote)
		cmd = exec.CommandContext(ctx, b.SSH[0], argv...)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if ctx.Err() == context.DeadlineExceeded {
		return out, errors.New("timed out")
	}
	if err != nil {
		msg := strings.TrimSpace(strings.SplitN(strings.TrimSpace(stderr.String()), "\n", 2)[0])
		if msg == "" {
			msg = err.Error()
		}
		return out, errors.New(clean(msg))
	}
	return out, nil
}

// poll asks machine i for its changed records and folds them in.
func (b *Board) poll(i int) {
	m := b.Machines[i]
	b.mu.Lock()
	since := b.state[i].since
	b.mu.Unlock()
	out, err := b.command(m, pollScript, m.Root, strconv.FormatInt(since, 10))
	now := time.Now()
	var res *pollResult
	if err == nil {
		res, err = parsePoll(out, now)
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	st := b.state[i]
	st.busy, st.polled = false, now
	if err != nil {
		st.err = err.Error()
		return
	}
	st.err, st.answered = "", now
	st.skew = now.Sub(time.Unix(res.now, 0))
	st.since = res.now - 2 // a second's granularity: look again at the last two
	st.root = res.root
	runs := map[string]*Run{}
	for id, mtime := range res.recs {
		// A fresh Run each poll: the screen may be reading the last one.
		path := res.root + "/" + id
		r := &Run{Dir: m.Name + ":" + path, Machine: m.Name}
		if old := st.runs[id]; old != nil {
			r.State, r.StateErr, r.Loaded = old.State, old.StateErr, old.Loaded
		}
		r.ModTime = time.Unix(mtime, 0).Add(st.skew)
		if data, ok := res.states[id]; ok {
			var s State
			if jerr := json.Unmarshal(data, &s); jerr != nil {
				r.StateErr = jerr
			} else {
				r.State, r.StateErr, r.Loaded = &s, nil, now
			}
		}
		runs[id] = r
	}
	st.runs = runs
}

type pollResult struct {
	now    int64
	root   string
	recs   map[string]int64
	states map[string][]byte
}

// parsePoll reads the poll script's output.
func parsePoll(out []byte, now time.Time) (*pollResult, error) {
	res := &pollResult{recs: map[string]int64{}, states: map[string][]byte{}}
	rd := bufio.NewReader(bytes.NewReader(out))
	first := true
	for {
		line, err := rd.ReadString('\n')
		if err == io.EOF && line == "" {
			break
		}
		if err != nil && err != io.EOF {
			return nil, err
		}
		line = strings.TrimSuffix(line, "\n")
		f := strings.SplitN(line, " ", 3)
		if first {
			first = false
			switch {
			case f[0] == "@noroot":
				return nil, errors.New("no record root there")
			case f[0] != "@ok" || len(f) < 3:
				return nil, errors.New("unexpected answer")
			}
			n, perr := strconv.ParseInt(f[1], 10, 64)
			if perr != nil {
				return nil, errors.New("unexpected answer")
			}
			res.now, res.root = n, f[2]
			continue
		}
		if len(f) != 3 {
			return nil, errors.New("unexpected answer")
		}
		n, perr := strconv.ParseInt(f[2], 10, 64)
		if perr != nil || n < 0 {
			return nil, errors.New("unexpected answer")
		}
		switch f[0] {
		case "@rec":
			res.recs[f[1]] = n
		case "@state":
			if n > 64<<20 {
				return nil, errors.New("state.json too large")
			}
			data := make([]byte, n)
			if _, err := io.ReadFull(rd, data); err != nil {
				return nil, errors.New("answer cut short")
			}
			if nl, err := rd.ReadByte(); err != nil || nl != '\n' {
				return nil, errors.New("answer cut short")
			}
			res.states[f[1]] = data
		default:
			return nil, errors.New("unexpected answer")
		}
		if err == io.EOF {
			break
		}
	}
	if first {
		return nil, errors.New("no answer")
	}
	return res, nil
}

// Poll polls every machine once and waits: the printed table uses it.
func (b *Board) Poll() {
	var wg sync.WaitGroup
	for i := range b.Machines {
		b.mu.Lock()
		b.state[i].busy = true
		b.mu.Unlock()
		wg.Add(1)
		go func(i int) { defer wg.Done(); b.poll(i) }(i)
	}
	wg.Wait()
}

// Refresh starts a poll for each machine that is due and returns what the
// board knows now, grouped by machine in board.json order. A machine that
// has not answered yet, or whose last poll failed, is one Signal row.
func (b *Board) Refresh(prev []*Run, now time.Time) []*Run {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []*Run
	for i, m := range b.Machines {
		st := b.state[i]
		if !st.busy && now.Sub(st.polled) >= b.Every {
			st.busy = true
			go b.poll(i)
		}
		if st.err != "" || st.answered.IsZero() {
			out = append(out, &Run{Dir: m.Name + ":", Machine: m.Name,
				Signal: &Signal{Machine: m.Name, Answered: st.answered, Err: st.err}})
			continue
		}
		var runs []*Run
		for _, r := range st.runs {
			runs = append(runs, r)
		}
		sortRuns(runs)
		out = append(out, runs...)
	}
	return out
}

// sortRuns puts open runs first, then the most recently updated.
func sortRuns(runs []*Run) {
	sort.SliceStable(runs, func(i, j int) bool {
		oi, oj := runs[i].Open(), runs[j].Open()
		if oi != oj {
			return oi
		}
		if !runs[i].ModTime.Equal(runs[j].ModTime) {
			return runs[i].ModTime.After(runs[j].ModTime)
		}
		return runs[i].Dir < runs[j].Dir
	})
}

// Tail reads a board run's display.txt in the background: each call
// returns what the last fetch brought and starts the next one.
func (b *Board) Tail(key string, offset int64, partial string) ([]string, int64, string, bool, error) {
	name, path, ok := strings.Cut(key, ":")
	idx := -1
	for i, m := range b.Machines {
		if m.Name == name {
			idx = i
		}
	}
	if !ok || idx < 0 || path == "" {
		return nil, offset, partial, false, errors.New("not a board record")
	}
	b.mu.Lock()
	j := b.tails[key]
	if j != nil && !j.done {
		b.mu.Unlock()
		return nil, offset, partial, false, nil
	}
	delete(b.tails, key)
	b.mu.Unlock()

	var lines []string
	var reset bool
	var err error
	next := offset
	if j != nil && (j.from == offset || j.reset) {
		switch {
		case j.err != nil:
			err = j.err
		case j.size < offset && !j.reset:
			// The file shrank: read it again from the start.
			b.startTail(idx, key, path, 0, true)
			return nil, offset, partial, false, nil
		default:
			if j.reset {
				offset, partial, reset = 0, "", true
			}
			lines, next, partial = splitTail(j.data, offset, partial)
		}
	}
	b.startTail(idx, key, path, next, false)
	return lines, next, partial, reset, err
}

func (b *Board) startTail(idx int, key, path string, from int64, reset bool) {
	j := &tailJob{from: from, reset: reset}
	b.mu.Lock()
	b.tails[key] = j
	b.mu.Unlock()
	go func() {
		out, err := b.command(b.Machines[idx], tailScript, path, strconv.FormatInt(from, 10))
		var size int64
		var data []byte
		if err == nil {
			head, rest, _ := bytes.Cut(out, []byte("\n"))
			switch {
			case string(head) == "@none":
				err = errors.New("no display.txt yet")
			case bytes.HasPrefix(head, []byte("@size ")):
				size, err = strconv.ParseInt(string(head[6:]), 10, 64)
				data = rest
				if len(data) > tailChunk {
					data = data[:tailChunk]
				}
			default:
				err = errors.New("unexpected answer")
			}
		}
		b.mu.Lock()
		j.data, j.size, j.err, j.done = data, size, err, true
		b.mu.Unlock()
	}()
}

// splitTail joins data to the unfinished line and splits it into complete
// lines and a new unfinished remainder.
func splitTail(data []byte, offset int64, partial string) ([]string, int64, string) {
	parts := strings.Split(partial+string(data), "\n")
	return parts[:len(parts)-1], offset + int64(len(data)), parts[len(parts)-1]
}

// RecordPath is the run's record directory on its own machine.
func (r *Run) RecordPath() string {
	if r.Machine != "" {
		return strings.TrimPrefix(r.Dir, r.Machine+":")
	}
	return r.Dir
}

// Nest orders rows so each child run follows its parent, one level deeper.
// A parent is matched by record path, on the child's own machine first,
// then on any machine (a run started through herdr on another machine).
// A child whose parent is not among the rows stays where it was.
func Nest(rows []*Run) []*Run {
	byKey := map[string]*Run{}
	byPath := map[string]*Run{}
	for _, r := range rows {
		r.Depth = 0
		byKey[r.Machine+"\x00"+r.RecordPath()] = r
		if _, dup := byPath[r.RecordPath()]; !dup {
			byPath[r.RecordPath()] = r
		}
	}
	parentOf := func(r *Run) *Run {
		if r.State == nil || r.State.Parent == "" {
			return nil
		}
		if p := byKey[r.Machine+"\x00"+r.State.Parent]; p != nil && p != r {
			return p
		}
		if p := byPath[r.State.Parent]; p != nil && p != r {
			return p
		}
		return nil
	}
	children := map[*Run][]*Run{}
	var roots []*Run
	for _, r := range rows {
		if p := parentOf(r); p != nil && !ancestor(r, p, parentOf) {
			children[p] = append(children[p], r)
			continue
		}
		roots = append(roots, r)
	}
	out := make([]*Run, 0, len(rows))
	var walk func(r *Run, depth int)
	walk = func(r *Run, depth int) {
		r.Depth = depth
		out = append(out, r)
		for _, c := range children[r] {
			walk(c, depth+1)
		}
	}
	for _, r := range roots {
		walk(r, 0)
	}
	return out
}

// ancestor reports whether r is p or one of p's ancestors: a parent loop.
func ancestor(r, p *Run, parentOf func(*Run) *Run) bool {
	for i := 0; p != nil && i < 64; i++ {
		if p == r {
			return true
		}
		p = parentOf(p)
	}
	return p != nil
}

// rowThemes caches the theme each run asked for, so a board row carries its
// own project's callsign and color. Resolved with the board's terminal.
var (
	rowThemes   = map[string]*Theme{}
	rowResolve  func(name, loudness string) (*Theme, error)
	rowThemesMu sync.Mutex
)

// RowTheme is the theme a run's row is drawn with: its own when it named
// one this machine has and the board is themed, else the board's.
func RowTheme(r *Run) *Theme {
	if r.State == nil || r.State.Theme.Name == "" || rowResolve == nil || cur.Name == "base" {
		return cur
	}
	key := r.State.Theme.Name + "\x00" + r.State.Theme.Loudness
	rowThemesMu.Lock()
	defer rowThemesMu.Unlock()
	t, ok := rowThemes[key]
	if !ok {
		var err error
		if t, err = rowResolve(r.State.Theme.Name, r.State.Theme.Loudness); err != nil || !t.Features.Callsigns {
			t = nil
		}
		rowThemes[key] = t
	}
	if t == nil {
		return cur
	}
	return t
}
