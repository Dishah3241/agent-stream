package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeRun creates a record directory with a state.json and a display.txt.
func writeRun(t *testing.T, root, id, state, display string, mtime time.Time) string {
	t.Helper()
	dir := filepath.Join(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if state != "" {
		p := filepath.Join(dir, "state.json")
		if err := os.WriteFile(p, []byte(state), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, mtime, mtime); err != nil {
			t.Fatal(err)
		}
	}
	if display != "" {
		if err := os.WriteFile(filepath.Join(dir, "display.txt"), []byte(display), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

const stateOpen = `{"schema":"agent-stream/state/1","id":"open1","status":"running","agent":"acp","model":"demo",
 "project":{"name":"proj","branch":"main"},"task":"Refactor calc.py","started_at":"2026-10-04T10:00:00Z",
 "activity":{"kind":"tool","text":"Run tests"},"step":null,"waiting":null,
 "todos":[{"n":1,"text":"Read","status":"done"},{"n":2,"text":"Run the tests","status":"active"}],
 "todo_counts":{"total":2,"done":1,"active":1,"pending":0,"dropped":0},
 "counts":{"tools":3,"tool_errors":0,"errors":0,"warnings":0,"waits":0,"turns":null,"tokens":null},
 "outcome":null}`

const stateWaiting = `{"status":"waiting","agent":"claude","project":{"name":"other"},"started_at":"2026-10-04T10:01:00Z",
 "waiting":{"kind":"permission","text":"Write notes.txt"},"todos":[],"todo_counts":{"total":0},"counts":{}}`

const stateOK = `{"status":"ended","agent":"acp","model":"demo","project":{"name":"proj","branch":"main"},
 "elapsed_s":75,"last_text":"All tests pass.","last_error":null,
 "todo_counts":{"total":3,"done":3},"counts":{"tools":3,"tokens":12400},
 "outcome":{"kind":"success","exit":0,"summary":null}}`

const stateFailed = `{"status":"ended","agent":"acp","project":{"name":"proj"},"elapsed_s":5,
 "last_text":"I will start.","last_error":"Run tests: AssertionError",
 "counts":{"tools":1,"tool_errors":1,"errors":1},"outcome":{"kind":"failed","exit":1}}`

func TestRefreshOrdersOpenFirstThenRecent(t *testing.T) {
	root := t.TempDir()
	base := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	writeRun(t, root, "old-ok", stateOK, "", base)
	writeRun(t, root, "new-failed", stateFailed, "", base.Add(time.Hour))
	writeRun(t, root, "open1", stateOpen, "", base.Add(-time.Hour))
	if err := os.MkdirAll(filepath.Join(root, "not-a-record"), 0o755); err != nil {
		t.Fatal(err)
	}
	runs := Refresh(nil, []string{root}, base)
	var got []string
	for _, r := range runs {
		got = append(got, filepath.Base(r.Dir))
	}
	want := []string{"open1", "new-failed", "old-ok"}
	if len(got) != len(want) {
		t.Fatalf("runs %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("runs %v want %v", got, want)
		}
	}
}

func TestRefreshReloadsOnlyChangedState(t *testing.T) {
	root := t.TempDir()
	base := time.Date(2026, 10, 4, 10, 0, 0, 0, time.UTC)
	dir := writeRun(t, root, "r", stateOpen, "", base)
	runs := Refresh(nil, []string{root}, base)
	first := runs[0].State
	runs = Refresh(runs, []string{root}, base)
	if runs[0].State != first {
		t.Error("an unchanged state.json is not re-read")
	}
	writeRun(t, root, "r", stateOK, "", base.Add(time.Minute))
	runs = Refresh(runs, []string{root}, base)
	if runs[0].State.Status != "ended" {
		t.Errorf("a changed state.json is re-read, status %q", runs[0].State.Status)
	}
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	if runs = Refresh(runs, []string{root}, base); len(runs) != 0 {
		t.Error("a removed run is dropped")
	}
}

func TestRecordRootIsOneRun(t *testing.T) {
	root := t.TempDir()
	dir := writeRun(t, root, "solo", stateOK, "x\n", time.Now())
	runs := Refresh(nil, []string{dir}, time.Now())
	if len(runs) != 1 || runs[0].Dir != dir {
		t.Fatalf("a record given as a root is one run: %+v", runs)
	}
}

func TestTailAcrossAppendsAndTruncation(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "display.txt")
	write := func(s string, appendMode bool) {
		flag := os.O_CREATE | os.O_WRONLY | os.O_TRUNC
		if appendMode {
			flag = os.O_CREATE | os.O_WRONLY | os.O_APPEND
		}
		f, err := os.OpenFile(p, flag, 0o644)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := f.WriteString(s); err != nil {
			t.Fatal(err)
		}
		f.Close()
	}
	if _, _, _, _, err := Tail(dir, 0, ""); err == nil {
		t.Error("a missing display.txt is an error the caller can show")
	}
	write("[tool] Read a\nhalf", false)
	lines, off, part, reset, err := Tail(dir, 0, "")
	if err != nil || reset || len(lines) != 1 || lines[0] != "[tool] Read a" || part != "half" {
		t.Fatalf("first read: %q %d %q %v %v", lines, off, part, reset, err)
	}
	write(" a line\n[done] Read\n", true)
	lines, off, part, reset, _ = Tail(dir, off, part)
	if reset || len(lines) != 2 || lines[0] != "half a line" || lines[1] != "[done] Read" || part != "" {
		t.Fatalf("append: %q %q %v", lines, part, reset)
	}
	lines, off2, _, _, _ := Tail(dir, off, "")
	if len(lines) != 0 || off2 != off {
		t.Fatalf("nothing new: %q %d/%d", lines, off2, off)
	}
	write("new\n", false)
	lines, _, _, reset, _ = Tail(dir, off, "")
	if !reset || len(lines) != 1 || lines[0] != "new" {
		t.Fatalf("a shrunk file is read again from the start: %q %v", lines, reset)
	}
}

func TestRunNowAndMarks(t *testing.T) {
	root := t.TempDir()
	now := time.Date(2026, 10, 4, 10, 3, 12, 0, time.UTC)
	cases := []struct {
		state, now, word string
	}{
		{stateOpen, "running Run tests", "running"},
		{stateWaiting, "waiting (permission) Write notes.txt", "waiting"},
		{stateOK, "All tests pass.", "success"},
		{stateFailed, "Run tests: AssertionError", "failed"},
		{`{"status":"starting","started_at":"2026-10-04T10:03:00Z","counts":{}}`, "starting", "starting"},
	}
	for i, c := range cases {
		dir := writeRun(t, root, string(rune('a'+i)), c.state, "", now)
		r := &Run{Dir: dir}
		r.State, r.ModTime, r.StateErr = LoadState(dir)
		if r.StateErr != nil {
			t.Fatalf("case %d: %v", i, r.StateErr)
		}
		if got := r.Now(); got != c.now {
			t.Errorf("case %d Now %q want %q", i, got, c.now)
		}
		if _, _, word := runMark(r, uni); word != c.word {
			t.Errorf("case %d word %q want %q", i, word, c.word)
		}
	}
	r := &Run{Dir: filepath.Join(root, "a")}
	r.State, _, _ = LoadState(r.Dir)
	if got := r.Elapsed(now); got != 3*time.Minute+12*time.Second {
		t.Errorf("open elapsed counts from started_at: %v", got)
	}
}

func TestLoadStateRefusesSymlink(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "r")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, "elsewhere.json")
	if err := os.WriteFile(target, []byte(stateOK), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, "state.json")); err != nil {
		t.Skip("no symlinks here")
	}
	if s, _, err := LoadState(dir); err == nil || s != nil {
		t.Error("a symlinked state.json is not followed")
	}
}
