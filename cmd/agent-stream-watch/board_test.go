package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
)

// fakeSSH is an ssh stand-in: it skips options, refuses the host "dead",
// and runs the remote command locally, so the board's real scripts run.
const fakeSSH = `#!/bin/sh
while [ $# -gt 0 ]; do
  case $1 in -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
host=$1; shift
echo "$host" >>"$FAKE_SSH_LOG"
if [ "$host" = dead ]; then echo "ssh: connect to host dead port 22: Connection refused" >&2; exit 255; fi
exec sh -c "$*"
`

func writeRecord(t *testing.T, root, id, state, display string) string {
	t.Helper()
	dir := filepath.Join(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "state.json"), []byte(state), 0o644); err != nil {
		t.Fatal(err)
	}
	if display != "" {
		if err := os.WriteFile(filepath.Join(dir, "display.txt"), []byte(display), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func boardFixture(t *testing.T) (string, string, string) {
	t.Helper()
	tmp := t.TempDir()
	bin := filepath.Join(tmp, "ssh")
	if err := os.WriteFile(bin, []byte(fakeSSH), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENT_STREAM_SSH", bin+" -q")
	t.Setenv("FAKE_SSH_LOG", filepath.Join(tmp, "ssh.log"))
	t.Setenv("XDG_CACHE_HOME", filepath.Join(tmp, "cache"))
	t.Setenv("HOME", tmp)

	forge := filepath.Join(tmp, "forge-runs")
	parent := writeRecord(t, forge, "20261004-050000-aaaa0001",
		`{"id":"20261004-050000-aaaa0001","status":"running","project":{"name":"forge"},"step":"integrating","theme":{"name":"observatory","loudness":"loud"}}`,
		"[step] integrating\n")
	writeRecord(t, forge, "20261004-050100-bbbb0002",
		`{"id":"20261004-050100-bbbb0002","status":"running","parent":"`+parent+`","project":{"name":"solver"},"step":"child work"}`, "")
	miini := filepath.Join(tmp, "miini-runs")
	writeRecord(t, miini, "20261004-040000-cccc0003",
		`{"id":"20261004-040000-cccc0003","status":"ended","project":{"name":"miini"},"outcome":{"kind":"success","exit":0}}`, "")
	// A record whose name a shell would treat specially is skipped.
	writeRecord(t, miini, "bad name", `{"status":"running","project":{"name":"never"}}`, "")

	cfg := filepath.Join(tmp, "board.json")
	board := `{"machines": [
	  {"name": "forge", "ssh": "forge.example", "root": "` + forge + `"},
	  {"name": "miini", "local": true, "root": "~/miini-runs"},
	  {"name": "air", "ssh": "dead"}
	]}`
	if err := os.WriteFile(cfg, []byte(board), 0o644); err != nil {
		t.Fatal(err)
	}
	return cfg, parent, tmp
}

func TestBoardPrintsEveryMachine(t *testing.T) {
	cfg, _, tmp := boardFixture(t)
	t.Setenv("NO_COLOR", "1")
	t.Setenv("COLUMNS", "120")
	var out, errb bytes.Buffer
	if rc := run([]string{"--once", "--board", cfg}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d: %s", rc, errb.String())
	}
	got := out.String()
	defer func() { machineWidth = 0 }()
	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	if !strings.HasPrefix(lines[0], "MACHINE") {
		t.Errorf("the board heads a MACHINE column:\n%s", got)
	}
	idx := func(s string) int {
		for i, l := range lines {
			if strings.Contains(l, s) {
				return i
			}
		}
		t.Errorf("missing %q:\n%s", s, got)
		return -1
	}
	f, child, m, a := idx("forge "), idx("solver"), idx("miini "), idx("air ")
	if f < 0 || child < 0 || m < 0 || a < 0 {
		return
	}
	if !strings.Contains(lines[child], "└ solver") && !strings.Contains(lines[child], "`- solver") {
		t.Errorf("a child run is indented under its parent: %q", lines[child])
	}
	if !(f < child && child < m && m < a) {
		t.Errorf("rows are grouped in board.json order with the child under its parent:\n%s", got)
	}
	if !strings.HasPrefix(lines[child], "        ") {
		t.Errorf("a machine's name heads its group only: %q", lines[child])
	}
	if !strings.Contains(lines[a], "no signal") || !strings.Contains(lines[a], "never answered") ||
		!strings.Contains(lines[a], "Connection refused") {
		t.Errorf("an unreachable machine is one no-signal row with the reason: %q", lines[a])
	}
	if strings.Contains(got, "never") && strings.Contains(got, "bad name") {
		t.Errorf("a record with an unsafe name is skipped:\n%s", got)
	}
	log, _ := os.ReadFile(filepath.Join(tmp, "ssh.log"))
	if strings.Contains(string(log), "miini") {
		t.Errorf("a local machine is read without ssh: %s", log)
	}
	if !strings.Contains(string(log), "forge.example") {
		t.Errorf("a machine is reached through its ssh destination: %s", log)
	}
}

func TestBoardKeepsUpAndTails(t *testing.T) {
	cfg, parent, _ := boardFixture(t)
	machines, err := LoadBoard(cfg)
	if err != nil {
		t.Fatal(err)
	}
	b := NewBoard(machines)
	t.Cleanup(b.Wait) // runs before the temp dirs are removed
	b.Every = 0
	rows := b.Refresh(nil, time.Now())
	for _, r := range rows {
		if r.Signal == nil || r.Signal.Err != "" {
			t.Fatalf("before the first answer each machine is dialing: %+v", r)
		}
	}
	b.Poll()
	rows = b.Refresh(nil, time.Now())
	var key string
	for _, r := range rows {
		if r.State != nil && r.State.Project.Name == "forge" {
			key = r.Dir
			if r.Machine != "forge" || r.RecordPath() != parent {
				t.Errorf("a board run is keyed by machine and path: %q", r.Dir)
			}
			if r.ModTime.IsZero() || time.Since(r.ModTime) > time.Minute {
				t.Errorf("mtime comes from the machine, adjusted to this clock: %v", r.ModTime)
			}
		}
	}
	if key == "" {
		t.Fatal("no forge run")
	}

	// A change on the machine shows on the next poll; a removed record goes.
	writeRecord(t, filepath.Dir(parent), filepath.Base(parent),
		`{"status":"ended","project":{"name":"forge"},"outcome":{"kind":"success"}}`, "")
	os.RemoveAll(filepath.Join(filepath.Dir(parent), "20261004-050100-bbbb0002"))
	b.Poll()
	n := 0
	for _, r := range b.Refresh(nil, time.Now()) {
		if r.Machine == "forge" {
			n++
			if r.State == nil || r.State.Status != "ended" {
				t.Errorf("the changed state.json is read again: %+v", r.State)
			}
		}
	}
	if n != 1 {
		t.Errorf("the removed record is dropped, got %d forge rows", n)
	}

	// The run view's tail: the first call starts a fetch, later calls
	// return what it brought.
	var lines []string
	off, part := int64(0), ""
	deadline := time.Now().Add(5 * time.Second)
	for len(lines) == 0 && time.Now().Before(deadline) {
		var got []string
		got, off, part, _, err = b.Tail(key, off, part)
		lines = append(lines, got...)
		time.Sleep(20 * time.Millisecond)
	}
	if len(lines) != 1 || lines[0] != "[step] integrating" || off != int64(len("[step] integrating\n")) {
		t.Errorf("tail over ssh: %q at %d (%v)", lines, off, err)
	}
	f, _ := os.OpenFile(filepath.Join(parent, "display.txt"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString("[done] build\n[no")
	f.Close()
	lines = nil
	deadline = time.Now().Add(5 * time.Second)
	for len(lines) == 0 && time.Now().Before(deadline) {
		var got []string
		got, off, part, _, _ = b.Tail(key, off, part)
		lines = append(lines, got...)
		time.Sleep(20 * time.Millisecond)
	}
	if len(lines) != 1 || lines[0] != "[done] build" || part != "[no" {
		t.Errorf("the tail continues from its offset and keeps the unfinished line: %q %q", lines, part)
	}
}

func TestBoardConfigChecks(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{
		"empty":     `{"machines": []}`,
		"bad name":  `{"machines": [{"name": "a b"}]}`,
		"twice":     `{"machines": [{"name": "a"}, {"name": "a"}]}`,
		"option":    `{"machines": [{"name": "a", "ssh": "-oProxyCommand=x"}]}`,
		"not json":  `machines`,
		"colon key": `{"machines": [{"name": "a:b"}]}`,
	} {
		p := filepath.Join(dir, "b.json")
		os.WriteFile(p, []byte(body), 0o644)
		if _, err := LoadBoard(p); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
	p := filepath.Join(dir, "ok.json")
	os.WriteFile(p, []byte(`{"machines": [{"name": "forge"}]}`), 0o644)
	ms, err := LoadBoard(p)
	if err != nil || ms[0].SSH != "forge" || ms[0].Root != "~/.agent-stream/runs" {
		t.Errorf("ssh defaults to the name and root to ~/.agent-stream/runs: %+v %v", ms, err)
	}
}

func TestParsePollRejectsShortAnswers(t *testing.T) {
	for _, out := range []string{"", "hello\n", "@ok x /r\n", "@ok 5 /r\n@state a 99\n{}\n", "@ok 5 /r\n@what a 1\n", "@noroot 5\n"} {
		if _, err := parsePoll([]byte(out), time.Now()); err == nil {
			t.Errorf("%q: want an error", out)
		}
	}
	res, err := parsePoll([]byte("@ok 100 /r s\n@rec a 90\n@state a 2\n{}\n@rec b 80\n"), time.Now())
	if err != nil || res.root != "/r s" || res.recs["b"] != 80 || string(res.states["a"]) != "{}" {
		t.Errorf("parse: %+v %v", res, err)
	}
}

func TestNest(t *testing.T) {
	mk := func(dir, parent string) *Run {
		return &Run{Dir: dir, State: &State{Status: "running", Parent: parent}}
	}
	a, b, c, d := mk("/r/a", ""), mk("/r/b", "/r/a"), mk("/r/c", "/r/b"), mk("/r/d", "/r/gone")
	got := Nest([]*Run{c, d, b, a})
	order := []*Run{d, a, b, c}
	for i := range order {
		if got[i] != order[i] {
			t.Fatalf("children follow parents, orphans stay: %v", got)
		}
	}
	if a.Depth != 0 || b.Depth != 1 || c.Depth != 2 || d.Depth != 0 {
		t.Errorf("depths %d %d %d %d", a.Depth, b.Depth, c.Depth, d.Depth)
	}
	// A parent loop never hides rows.
	x, y := mk("/r/x", "/r/y"), mk("/r/y", "/r/x")
	if got := Nest([]*Run{x, y}); len(got) != 2 {
		t.Errorf("a loop keeps both rows: %v", got)
	}
	// Across machines: a child on another machine nests by path.
	p := &Run{Dir: "forge:/r/p", Machine: "forge", State: &State{Status: "running"}}
	q := &Run{Dir: "pc:/s/q", Machine: "pc", State: &State{Status: "running", Parent: "/r/p"}}
	if got := Nest([]*Run{q, p}); got[0] != p || q.Depth != 1 {
		t.Errorf("cross-machine nesting: %v", got)
	}
}

func TestBoardModelPollsAndOpensARemoteRun(t *testing.T) {
	cfg, _, _ := boardFixture(t)
	machines, err := LoadBoard(cfg)
	if err != nil {
		t.Fatal(err)
	}
	b := NewBoard(machines)
	t.Cleanup(b.Wait) // runs before the temp dirs are removed
	b.Every = 10 * time.Millisecond
	machineWidth = 7
	defer func() { machineWidth = 0 }()
	m := newSourceModel(b, true, time.Now)
	m.Update(tea.WindowSizeMsg{Width: 120, Height: 30})
	var screen string
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		m.Update(tickMsg(time.Now()))
		screen = plain(m.render())
		if strings.Contains(screen, "integrating") && strings.Contains(screen, "no signal") {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !strings.Contains(screen, "integrating") || !strings.Contains(screen, "no signal") ||
		!strings.Contains(screen, "forge, miini, air") {
		t.Fatalf("the board fills in as machines answer:\n%s", screen)
	}
	// The no-signal row does not open; the first run row does.
	for _, r := range m.visible() {
		if r.State != nil && r.State.Project.Name == "forge" {
			m.sel = r.Dir
		}
	}
	m.Update(key("enter"))
	if m.mode != runMode {
		t.Fatal("enter opens the selected board run")
	}
	for time.Now().Before(deadline) {
		m.Update(tickMsg(time.Now()))
		screen = plain(m.render())
		if strings.Contains(screen, "integrating") && len(m.raw) > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(m.raw) != 1 || m.raw[0] != "[step] integrating" {
		t.Errorf("the run view tails display.txt over ssh: %q\n%s", m.raw, screen)
	}
}

func TestFleetHeadingLinesUpWithShipsAndMachines(t *testing.T) {
	th, _, err := LoadTheme(filepath.Join(themesDir(t), "space.json"), colorprofile.TrueColor)
	if err != nil {
		t.Fatal(err)
	}
	Use(th)
	machineWidth = 7
	t.Cleanup(func() { Use(Base()); machineWidth = 0 })
	r := &Run{Dir: "forge:/r/a", Machine: "forge", State: &State{Status: "running", Project: Project{Name: "proj"}}}
	head := FleetHead(120, false)
	row := plain(FleetLines([]*Run{r}, time.Now(), cur.Marks(false), 120, "", false, 0)[0])
	col := cur.Words.Columns
	for _, pair := range [][2]string{{col["ship"], cur.Callsign(runID(r))}, {col["state"], cur.State("running")}, {col["project"], "proj"}} {
		hi := strings.Index(head, pair[0])
		ri := strings.Index(row, pair[1])
		// Compare display columns: the row's mark may be multi-byte.
		if hi < 0 || ri < 0 || len([]rune(head[:hi])) != len([]rune(row[:ri])) {
			t.Errorf("%q heads column %d but %q starts at %d:\n%s\n%s", pair[0], hi, pair[1], ri, head, row)
		}
	}
}
