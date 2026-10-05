package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

const displayOK = `[note] acp agent demo 2.1 (protocol 2)
[run] acp demo session sess-dem
I will read calc.py.
[todo] 1/2 active Read calc.py
[todo] 2/2 pending Run the tests
[tool] Read calc.py
[done] Read calc.py
[todo] 1/2 done Read calc.py
[todo] 2/2 active Run the tests
[wait] permission: Run python3 tests.py
[tool] Run python3 tests.py
[done] Run python3 tests.py
[todo] 2/2 done Run the tests
All tests pass.
[run] result end_turn (12400 tokens)
[end] success exit 0 elapsed 75s record /r/ok
`

func key(s string) tea.KeyPressMsg {
	switch s {
	case "enter":
		return tea.KeyPressMsg{Code: tea.KeyEnter}
	case "esc":
		return tea.KeyPressMsg{Code: tea.KeyEscape}
	case "down":
		return tea.KeyPressMsg{Code: tea.KeyDown}
	}
	r := []rune(s)
	return tea.KeyPressMsg{Code: r[0], Text: s}
}

func fixtureRoot(t *testing.T, now time.Time) string {
	root := t.TempDir()
	writeRun(t, root, "ok", stateOK, displayOK, now.Add(-time.Hour))
	writeRun(t, root, "failed", stateFailed, "[tool] Run tests\n[error] Run tests: AssertionError\n", now.Add(-2*time.Hour))
	writeRun(t, root, "open1", stateOpen, "[tool] Run tests\n", now.Add(-10*time.Minute))
	return root
}

func send(m *model, msgs ...tea.Msg) {
	for _, msg := range msgs {
		m.Update(msg)
	}
}

func checkFits(t *testing.T, view string, w, h int) {
	t.Helper()
	lines := strings.Split(view, "\n")
	if len(lines) != h {
		t.Errorf("view has %d lines, the terminal %d", len(lines), h)
	}
	for i, l := range lines {
		if ansi.StringWidth(l) > w {
			t.Errorf("line %d is %d wide, the terminal %d: %q", i, ansi.StringWidth(l), w, l)
		}
	}
}

func TestFleetView(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 3, 12, 0, time.UTC)
	root := fixtureRoot(t, now)
	m := newModel([]string{root}, false, func() time.Time { return now })
	send(m, tea.WindowSizeMsg{Width: 120, Height: 20})
	v := plain(m.render())
	checkFits(t, v, 120, 20)
	for _, want := range []string{"1 open", "2 ended", "STATE", "PROJECT", "AGENT", "NOW",
		"▸ ▸ running", "proj · main", "1/2", "quiet 10m00s · running Run tests",
		"✓ success", "All tests pass.", "✗ failed", "Run tests: AssertionError", "enter open"} {
		if !strings.Contains(v, want) {
			t.Errorf("fleet view lacks %q:\n%s", want, v)
		}
	}
	if strings.Index(v, "running") > strings.Index(v, "success") {
		t.Error("open runs come first")
	}
	send(m, key("j"))
	if m.sel != filepath.Join(root, "ok") {
		t.Errorf("j moves the selection, sel %q", m.sel)
	}
	send(m, key("j"), key("j"), key("j"))
	if m.sel != filepath.Join(root, "failed") {
		t.Errorf("the selection stops at the last row, sel %q", m.sel)
	}
}

func TestFleetNarrowDropsAgentColumn(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 3, 12, 0, time.UTC)
	m := newModel([]string{fixtureRoot(t, now)}, false, func() time.Time { return now })
	send(m, tea.WindowSizeMsg{Width: 70, Height: 12})
	v := plain(m.render())
	checkFits(t, v, 70, 12)
	if strings.Contains(v, "AGENT") {
		t.Error("a narrow terminal drops the agent column")
	}
}

func TestRunViewOpensFollowsAndReturns(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 3, 12, 0, time.UTC)
	root := fixtureRoot(t, now)
	m := newModel([]string{root}, false, func() time.Time { return now })
	send(m, tea.WindowSizeMsg{Width: 100, Height: 30}, key("j"), key("enter"))
	if m.mode != runMode || m.dir != filepath.Join(root, "ok") {
		t.Fatalf("enter opens the selected run: mode %v dir %q", m.mode, m.dir)
	}
	v := plain(m.render())
	checkFits(t, v, 100, 30)
	for _, want := range []string{"✓ proj · main", "acp demo · 1m15s", "plan 3/3 done · 3 tools · 12.4k tokens",
		"┌─ · Read calc.py", "└─ ✓ Read calc.py", "~ waiting (permission) Run python3 tests.py",
		"│ ✓ result end_turn (12400 tokens)", "── ✓ success exit 0", "✓ success · exit 0 · 1m15s",
		"esc fleet", "following"} {
		if !strings.Contains(v, want) {
			t.Errorf("run view lacks %q:\n%s", want, v)
		}
	}
	if strings.Contains(v, "[tool]") || strings.Contains(v, "[todo]") {
		t.Error("protocol labels are rendered, not shown raw")
	}
	send(m, key("esc"))
	if m.mode != fleetMode || m.sel != filepath.Join(root, "ok") {
		t.Error("esc returns to the fleet with the run still selected")
	}
}

func TestRunViewTailsAppendsAndStopsFollowingWhenScrolled(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 3, 12, 0, time.UTC)
	root := fixtureRoot(t, now)
	dir := filepath.Join(root, "open1")
	m := newModel([]string{root}, false, func() time.Time { return now })
	send(m, tea.WindowSizeMsg{Width: 80, Height: 16})
	m.openRun(dir)
	v := plain(m.render())
	checkFits(t, v, 80, 16)
	for _, want := range []string{"▸ proj · main", "task  Refactor calc.py", "✓ 1/2 Read", "▸ 2/2 Run the tests", "┌─ · Run tests"} {
		if !strings.Contains(v, want) {
			t.Errorf("open run view lacks %q:\n%s", want, v)
		}
	}
	appendTo := func(s string) {
		f, err := os.OpenFile(filepath.Join(dir, "display.txt"), os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			t.Fatal(err)
		}
		f.WriteString(s)
		f.Close()
	}
	var b bytes.Buffer
	for i := 0; i < 40; i++ {
		b.WriteString("line of output\n")
	}
	b.WriteString("streaming ha")
	appendTo(b.String())
	send(m, tickMsg(now))
	if !m.vp.AtBottom() || !strings.Contains(plain(m.render()), "streaming ha") {
		t.Errorf("the view follows the tail and shows the unfinished line:\n%s", plain(m.render()))
	}
	send(m, key("k"), key("k"))
	if m.vp.AtBottom() {
		t.Fatal("k scrolls up")
	}
	appendTo("lf done\nmore\n")
	send(m, tickMsg(now))
	if m.vp.AtBottom() {
		t.Error("new lines do not pull a reader who scrolled up back to the bottom")
	}
	if !strings.Contains(plain(m.render()), "G follows") {
		t.Error("the footer says how to follow again")
	}
	send(m, key("G"))
	if !m.vp.AtBottom() || !strings.Contains(plain(m.render()), "more") {
		t.Error("G returns to the tail")
	}
	send(m, key("p"))
	if strings.Contains(plain(m.render()), "▸ 2/2 Run the tests") {
		t.Error("p hides the plan panel")
	}
}

func TestRunViewMarkdownToggle(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 3, 12, 0, time.UTC)
	root := t.TempDir()
	dir := writeRun(t, root, "md", stateOK, "Some **bold** words.\n\n[tool] Read x\n[done] Read\n[end] success exit 0 elapsed 1s record /r\n", now)
	m := newModel([]string{root}, false, func() time.Time { return now })
	send(m, tea.WindowSizeMsg{Width: 80, Height: 20})
	m.openRun(dir)
	if !strings.Contains(plain(m.render()), "**bold**") {
		t.Fatal("plain mode shows the prose as written")
	}
	send(m, key("m"))
	v := plain(m.render())
	if strings.Contains(v, "**bold**") || !strings.Contains(v, "bold") || !strings.Contains(v, "┌─ · Read x") {
		t.Errorf("m renders finished prose as markdown and keeps the cards:\n%s", v)
	}
}

func TestRunViewMarkdownShowsStreamingProse(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 3, 12, 0, time.UTC)
	root := t.TempDir()
	dir := writeRun(t, root, "live", stateOpen, "[tool] Read x\n[done] Read\n", now)
	m := newModel([]string{root}, false, func() time.Time { return now })
	send(m, tea.WindowSizeMsg{Width: 80, Height: 24})
	m.openRun(dir)
	send(m, key("m"))
	f, err := os.OpenFile(filepath.Join(dir, "display.txt"), os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("Here is the **answer**.\n\n- first\n- second\n")
	f.Close()
	send(m, tickMsg(now))
	v := plain(m.render())
	if !strings.Contains(v, "answer") || strings.Contains(v, "**answer**") || !strings.Contains(v, "second") {
		t.Errorf("prose held for markdown is shown rendered while it streams:\n%s", v)
	}
}

func TestOnceTable(t *testing.T) {
	now := time.Date(2026, 10, 4, 10, 3, 12, 0, time.UTC)
	root := fixtureRoot(t, now)
	got := plain(FleetTable(Refresh(nil, []string{root}, now), now, true, 120))
	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	if len(lines) != 4 || !strings.HasPrefix(lines[0], "  STATE") {
		t.Fatalf("heading plus three rows:\n%s", got)
	}
	if !strings.HasPrefix(lines[1], "> running") || !strings.HasPrefix(lines[2], "+ success") || !strings.HasPrefix(lines[3], "x failed") {
		t.Errorf("ASCII marks, open first:\n%s", got)
	}
	for _, r := range got {
		if r > 127 {
			t.Errorf("ASCII table printed %q:\n%s", r, got)
			break
		}
	}
	if FleetTable(nil, now, true, 80) != "no runs\n" {
		t.Error("an empty root says so")
	}
}

// The printed table goes through the color-profile writer: a pipe, NO_COLOR,
// and AGENT_RUN_COLOR=never get no escape bytes at all, and
// AGENT_RUN_COLOR=always gets the 16-color palette, never 256 or true color.
func TestOncePrintsThroughTheProfileWriter(t *testing.T) {
	now := time.Now()
	root := fixtureRoot(t, now)
	for _, env := range []map[string]string{
		{},
		{"NO_COLOR": "1", "AGENT_RUN_COLOR": "always"},
		{"AGENT_RUN_COLOR": "never"},
	} {
		for k, v := range env {
			t.Setenv(k, v)
		}
		var out, errb bytes.Buffer
		if rc := run([]string{"--once", root}, &out, &errb); rc != 0 {
			t.Fatalf("exit %d: %s", rc, errb.String())
		}
		if strings.Contains(out.String(), "\x1b") {
			t.Errorf("env %v: escape bytes in the printed table:\n%q", env, out.String())
		}
		if !strings.Contains(out.String(), "running") {
			t.Errorf("env %v: table lost its rows:\n%s", env, out.String())
		}
		for k := range env {
			os.Unsetenv(k)
		}
	}
	t.Setenv("AGENT_RUN_COLOR", "always")
	var out, errb bytes.Buffer
	if rc := run([]string{"--once", root}, &out, &errb); rc != 0 {
		t.Fatalf("exit %d: %s", rc, errb.String())
	}
	s := out.String()
	if !strings.Contains(s, "\x1b[36m") {
		t.Errorf("AGENT_RUN_COLOR=always uses the 16-color cyan for running:\n%q", s)
	}
	if strings.Contains(s, "38;5;") || strings.Contains(s, "38;2;") {
		t.Errorf("forced color stays within 16 colors:\n%q", s)
	}
}

func TestRunCommandPrintsTableWhenNotATerminal(t *testing.T) {
	now := time.Now()
	root := fixtureRoot(t, now)
	var out, errb bytes.Buffer
	if rc := run([]string{root}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d: %s", rc, errb.String())
	}
	if !strings.Contains(out.String(), "STATE") || !strings.Contains(out.String(), "success") {
		t.Errorf("piped output is the fleet table:\n%s", out.String())
	}
	if strings.Contains(out.String(), "\x1b[") {
		t.Error("piped output has no terminal controls")
	}
	if rc := run([]string{"--bogus"}, &out, &errb); rc != 2 {
		t.Errorf("an unknown flag is a usage error, rc %d", rc)
	}
}
