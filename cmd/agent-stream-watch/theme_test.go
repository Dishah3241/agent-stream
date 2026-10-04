package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/colorprofile"
)

func tea80x20() tea.Msg { return tea.WindowSizeMsg{Width: 80, Height: 20} }

// themesDir is the repository's shipped themes.
func themesDir(t *testing.T) string {
	t.Helper()
	d, err := filepath.Abs("../../themes")
	if err != nil {
		t.Fatal(err)
	}
	return d
}

var shipped = []string{"space", "observatory", "blueprint", "radio", "bottling"}

// useTheme loads a shipped theme for the test and restores the base after.
func useTheme(t *testing.T, name string, eggs bool) *Theme {
	t.Helper()
	t.Setenv("AGENT_STREAM_THEMES", themesDir(t))
	e := eggs
	th, err := ResolveTheme(Choice{Theme: name, Eggs: &e}, colorprofile.TrueColor, false, false)
	if err != nil {
		t.Fatalf("theme %s: %v", name, err)
	}
	Use(th)
	t.Cleanup(func() { Use(Base()) })
	return th
}

func TestShippedThemesLoadOnEveryProfile(t *testing.T) {
	for _, name := range shipped {
		for _, p := range []colorprofile.Profile{colorprofile.TrueColor, colorprofile.ANSI256, colorprofile.ANSI} {
			th, _, err := LoadTheme(filepath.Join(themesDir(t), name+".json"), p)
			if err != nil {
				t.Fatalf("%s on %v: %v", name, p, err)
			}
			if th.Name != name {
				t.Errorf("%s: name %q", name, th.Name)
			}
			if th.Features.Background == "" || th.Features.Gauge == "" || !th.Features.Callsigns {
				t.Errorf("%s: every shipped theme has a background, a gauge, and callsigns: %+v", name, th.Features)
			}
			for _, key := range []string{"running", "waiting", "success", "failed", "cancelled"} {
				if th.State(key) == "" || th.State(key) == key && name != "space" && key == "running" {
					t.Errorf("%s: state %s needs a themed word, got %q", name, key, th.State(key))
				}
			}
		}
	}
}

// Every glyph a theme draws must be one column wide, or tables and borders
// drift (emoji such as 🚀 are two wide and multiplexers disagree on them).
func TestThemeGlyphsAreSingleWidth(t *testing.T) {
	for _, name := range shipped {
		th, _, err := LoadTheme(filepath.Join(themesDir(t), name+".json"), colorprofile.TrueColor)
		if err != nil {
			t.Fatal(err)
		}
		for _, mk := range []marks{th.Uni, th.Asc} {
			for _, g := range []string{mk.active, mk.lit, mk.pending, mk.drop, mk.launch, mk.trail, mk.ahead, mk.cardOpen, mk.cardClose} {
				if g != "" && lipgloss.Width(g) != 1 {
					t.Errorf("%s: glyph %q is %d wide", name, g, lipgloss.Width(g))
				}
			}
			for _, set := range []string{mk.sky, mk.field, mk.orbit} {
				for _, r := range set {
					if lipgloss.Width(string(r)) != 1 {
						t.Errorf("%s: glyph %q is %d wide", name, string(r), lipgloss.Width(string(r)))
					}
				}
			}
		}
		for _, r := range th.Asc.sky + th.Asc.field + th.Asc.active + th.Asc.lit + th.Asc.trail {
			if r > 127 {
				t.Errorf("%s: ASCII set holds %q", name, string(r))
			}
		}
	}
}

// The same ids give the same callsigns in Bash (tests/agent-present.test.sh
// checks this table too) and in an independent Python computation.
func TestCallsignsAreStableAcrossLanguages(t *testing.T) {
	cases := []struct{ theme, id, want string }{
		{"space", "20261004-050000-ab12cd34", "ANTARES-4"},
		{"space", "real1", "MIRA-3"},
		{"observatory", "20261004-050000-ab12cd34", "SUBARU-8"},
		{"observatory", "real1", "LICK-1"},
		{"bottling", "20261004-050000-ab12cd34", "BEAN-7"},
		{"bottling", "real1", "POD-2"},
	}
	for _, c := range cases {
		th := useTheme(t, c.theme, false)
		if got := th.Callsign(c.id); got != c.want {
			t.Errorf("%s %s: callsign %q, want %q", c.theme, c.id, got, c.want)
		}
	}
	if got := useTheme(t, "space", false).Callsign("20261004-051701-ffffffff"); got != "POLLUX-9" {
		t.Errorf("without eggs an id with 1701 keeps its callsign, got %q", got)
	}
	if got := useTheme(t, "space", true).Callsign("20261004-051701-ffffffff"); got != "ENTERPRISE" {
		t.Errorf("with eggs an id with 1701 is the ENTERPRISE, got %q", got)
	}
}

func TestResolveThemeRules(t *testing.T) {
	t.Setenv("AGENT_STREAM_THEMES", themesDir(t))
	t.Setenv("AGENT_STREAM_EGGS", "")
	check := func(what string, c Choice, p colorprofile.Profile, ascii bool, wantName string, wantErr bool) *Theme {
		t.Helper()
		th, err := ResolveTheme(c, p, ascii, false)
		if (err != nil) != wantErr {
			t.Errorf("%s: err %v, want error %v", what, err, wantErr)
		}
		if th.Name != wantName {
			t.Errorf("%s: theme %q, want %q", what, th.Name, wantName)
		}
		return th
	}
	check("default is space", Choice{}, colorprofile.TrueColor, false, "space", false)
	check("a pipe gets the base", Choice{Theme: "radio"}, colorprofile.NoTTY, false, "base", false)
	check("NO_COLOR gets the base", Choice{Theme: "radio"}, colorprofile.Ascii, false, "base", false)
	check("ASCII marks get the base", Choice{Theme: "radio"}, colorprofile.TrueColor, true, "base", false)
	check("quiet is the base", Choice{Theme: "radio", Loudness: Quiet}, colorprofile.TrueColor, false, "base", false)
	check("plain is the base", Choice{Theme: "plain"}, colorprofile.TrueColor, false, "base", false)
	check("an unknown theme warns", Choice{Theme: "nope"}, colorprofile.TrueColor, false, "base", true)
	check("a bad loudness warns", Choice{Theme: "radio", Loudness: "deafening"}, colorprofile.TrueColor, false, "base", true)

	loud := check("loud has eggs", Choice{Theme: "radio"}, colorprofile.TrueColor, false, "radio", false)
	if loud.Eggs == nil || !loud.Animated() {
		t.Error("loud radio has eggs and motion")
	}
	bal := check("balanced", Choice{Theme: "radio", Loudness: Balanced}, colorprofile.TrueColor, false, "radio", false)
	if bal.Eggs != nil || bal.Animated() {
		t.Error("balanced has no eggs and no motion")
	}
	bot := check("bottling", Choice{Theme: "bottling"}, colorprofile.TrueColor, false, "bottling", false)
	if bot.Eggs != nil {
		t.Error("bottling ships with eggs off")
	}
	on := true
	bot = check("bottling with eggs", Choice{Theme: "bottling", Eggs: &on}, colorprofile.TrueColor, false, "bottling", false)
	if bot.Eggs == nil {
		t.Error("a project can turn bottling's eggs on")
	}
	t.Setenv("AGENT_STREAM_EGGS", "0")
	if th := check("AGENT_STREAM_EGGS=0", Choice{Theme: "radio"}, colorprofile.TrueColor, false, "radio", false); th.Eggs != nil {
		t.Error("AGENT_STREAM_EGGS=0 turns eggs off")
	}
}

// A project picks its theme in .agent-stream/config.json, can ship its own
// theme.json, and a theme.json named like a shipped theme overrides it.
func TestProjectConfig(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	t.Setenv("AGENT_STREAM_THEMES", themesDir(t))
	proj := t.TempDir()
	if out, err := exec.Command("git", "-C", proj, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	sub := filepath.Join(proj, "deep", "dir")
	os.MkdirAll(sub, 0o755)
	os.MkdirAll(filepath.Join(proj, ".agent-stream"), 0o755)
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(proj, ".agent-stream", name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("config.json", `{"schema":"agent-stream/project/1","theme":"observatory","loudness":"balanced"}`)
	c, err := ProjectChoice(sub)
	if err != nil || c.Theme != "observatory" || c.Loudness != Balanced {
		t.Fatalf("config from a subdirectory: %+v %v", c, err)
	}
	th, err := ResolveTheme(c, colorprofile.TrueColor, false, false)
	if err != nil || th.Name != "observatory" || th.Animated() {
		t.Fatalf("observatory at balanced: %v %v", th.Name, err)
	}

	write("theme.json", `{"schema":"agent-stream/theme/1","name":"observatory","words":{"fleet_title":"OUR DOME"}}`)
	th, _ = ResolveTheme(c, colorprofile.TrueColor, false, false)
	if th.Words.FleetTitle != "OUR DOME" {
		t.Errorf("a project theme.json named observatory overrides the shipped one, got %q", th.Words.FleetTitle)
	}

	write("config.json", `{"schema":"agent-stream/project/1","theme":"project"}`)
	c, _ = ProjectChoice(sub)
	th, err = ResolveTheme(c, colorprofile.TrueColor, false, false)
	if err != nil || th.Words.FleetTitle != "OUR DOME" {
		t.Errorf("theme \"project\" uses .agent-stream/theme.json: %v %q", err, th.Words.FleetTitle)
	}

	write("config.json", `{"schema":"agent-stream/project/9"}`)
	if _, err := ProjectChoice(sub); err == nil {
		t.Error("a wrong schema is an error")
	}
	if c, err := ProjectChoice(t.TempDir()); err != nil || c.Theme != "" {
		t.Errorf("no git repository means no project config: %+v %v", c, err)
	}
}

func TestBadThemeFiles(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{
		"noschema":   `{"name":"x"}`,
		"badjson":    `{"schema":`,
		"badbg":      `{"schema":"agent-stream/theme/1","background":{"kind":"lava"}}`,
		"badgauge":   `{"schema":"agent-stream/theme/1","gauge":"speedometer"}`,
		"badfeature": `{"schema":"agent-stream/theme/1","features":{"confetti":true}}`,
	} {
		p := filepath.Join(dir, name+".json")
		os.WriteFile(p, []byte(body), 0o644)
		if _, _, err := LoadTheme(p, colorprofile.TrueColor); err == nil {
			t.Errorf("%s must be rejected", name)
		}
	}
	p := filepath.Join(dir, "evil.json")
	os.WriteFile(p, []byte(`{"schema":"agent-stream/theme/1","words":{"fleet_title":"A\u001b[2JB"},"glyphs":{"unicode":{"active":"\u0007>"}}}`), 0o644)
	th, _, err := LoadTheme(p, colorprofile.TrueColor)
	if err != nil {
		t.Fatal(err)
	}
	if strings.ContainsAny(th.Words.FleetTitle+th.Uni.active, "\x1b\x07") {
		t.Errorf("control bytes in a theme are stripped: %q %q", th.Words.FleetTitle, th.Uni.active)
	}
}

func TestBackgroundMath(t *testing.T) {
	for _, name := range shipped {
		th := useTheme(t, name, false)
		mk := th.Marks(false)
		a := th.Background(mk, 60, 3, 42, 0, 0.5)
		if a == "" || lipgloss.Width(a) != 60 {
			t.Fatalf("%s: a background row is exactly the width, got %d: %q", name, lipgloss.Width(a), plain(a))
		}
		if b := th.Background(mk, 60, 3, 42, 0, 0.5); b != a {
			t.Errorf("%s: the same seed and frame draw the same row", name)
		}
		if strings.TrimSpace(plain(a)) == "" {
			t.Errorf("%s: the background draws something", name)
		}
		if th.Background(th.Marks(true), 60, 3, 42, 0, 0.5) != "" {
			t.Errorf("%s: no background with ASCII marks", name)
		}
	}
	th := useTheme(t, "observatory", false)
	short := strings.Count(plain(th.Background(th.Marks(false), 120, 1, 7, 0, 0)), "·")
	long := strings.Count(plain(th.Background(th.Marks(false), 120, 1, 7, 0, 1)), "·")
	if long <= short {
		t.Errorf("star trails grow with elapsed time: %d at the start, %d after six hours", short, long)
	}
	bal := *th
	bal.Loudness = Balanced
	if bal.Background(th.Marks(false), 80, 2, 9, 0, 0.3) != bal.Background(th.Marks(false), 80, 2, 9, 5, 0.3) {
		t.Error("a balanced theme does not move with the frame")
	}
	if Base().Background(uni, 80, 0, 1, 0, 0) != "" {
		t.Error("the base has no background")
	}
}

func TestGauges(t *testing.T) {
	statuses := []string{"done", "done", "active", "pending"}
	cases := map[string]string{
		"space":       "✦━✦━➤┈·",
		"observatory": "",
		"blueprint":   "|<",
		"radio":       "♪─♪─●·",
		"bottling":    "▕●●●●●○",
	}
	for name, want := range cases {
		th := useTheme(t, name, false)
		got := plain(th.Gauge(th.Marks(false), statuses, 1, 13))
		if want != "" && !strings.Contains(got, want) {
			t.Errorf("%s gauge %q, want it to contain %q", name, got, want)
		}
		if lipgloss.Width(got) > 13 || got == "" {
			t.Errorf("%s gauge %q exceeds 13 columns or is empty", name, got)
		}
	}
	th := useTheme(t, "blueprint", false)
	if got := plain(th.Gauge(th.Marks(false), statuses, 1, 24)); !strings.Contains(got, "2 of 4") {
		t.Errorf("the dimension line names the count: %q", got)
	}
	if got := Base().Gauge(uni, statuses, 1, 13); got != "2/4" {
		t.Errorf("the base gauge is done/total, got %q", got)
	}
}

func TestThemeWordsInTheRenderer(t *testing.T) {
	useTheme(t, "space", false)
	got := renderAll(NewRenderer(false, 80), "[tool] Read x", "[done] Read", "[error] Bash: boom", "[wait] permission: Write y", "[step] counting", "[todo] 1/2 done a", "[todo] 2/2 active b")
	for _, want := range []string{"burn Read x", "✓ Read nominal", "✗ anomaly Bash: boom", "~ holding (permission) Write y", "heading counting", "flight plan", "✦ 1/2 a", "➤ 2/2 b"} {
		if !strings.Contains(got, want) {
			t.Errorf("space renders %q:\n%s", want, got)
		}
	}
	useTheme(t, "bottling", false)
	got = renderAll(NewRenderer(false, 80), "[tool] Pour x", "[error] Pour: overflow")
	if !strings.Contains(got, "fill Pour x") || !strings.Contains(got, "✗ spill Pour: overflow") {
		t.Errorf("bottling words:\n%s", got)
	}
	got = renderAll(NewRenderer(true, 80), "[todo] 1/1 done a")
	for _, r := range got {
		if r > 127 {
			t.Errorf("ASCII marks under a theme stay ASCII: %q", got)
			break
		}
	}
}

func TestEggs(t *testing.T) {
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	ended := func(kind string, tools, errs, total, done int, elapsed int64) *Run {
		var s State
		raw := fmt.Sprintf(`{"status":"ended","elapsed_s":%d,"started_at":"2026-10-04T10:00:00Z","ended_at":"2026-10-04T11:00:00Z",
			"outcome":{"kind":%q},"counts":{"tools":%d,"errors":%d},"todo_counts":{"total":%d,"done":%d}}`, elapsed, kind, tools, errs, total, done)
		if err := json.Unmarshal([]byte(raw), &s); err != nil {
			t.Fatal(err)
		}
		return &Run{Dir: "/r/x", State: &s, ModTime: now}
	}
	useTheme(t, "space", true)
	cases := []struct {
		r    *Run
		want string
	}{
		{ended("success", 42, 0, 0, 0, 60), "42 burns"},
		{ended("failed", 3, 1, 4, 3, 60), "Seldon crisis"},
		{ended("success", 9, 12, 0, 0, 60), "bugs persist"},
		{ended("success", 9, 0, 5, 5, 60), "amaze"},
		{ended("success", 9, 0, 0, 0, 7200), "Seldon would approve"},
		{ended("success", 9, 0, 0, 0, 90000), "Sol 2"},
		{ended("success", 9, 0, 0, 0, 60), ""},
	}
	for _, c := range cases {
		got := RunEgg(c.r, now)
		if (c.want == "" && got != "") || !strings.Contains(got, c.want) {
			t.Errorf("egg %q, want %q", got, c.want)
		}
	}
	quiet := ended("success", 1, 0, 0, 0, 60)
	quiet.State.Status = "running"
	quiet.ModTime = now.Add(-12 * time.Minute)
	if got := runNowEgg(quiet, now); !strings.Contains(got, "dark forest") {
		t.Errorf("a run quiet for 12m is a dark forest, got %q", got)
	}
	if got := FleetEgg([]*Run{ended("success", 1, 0, 0, 0, 60)}, now); !strings.Contains(got, "dead channel") {
		t.Errorf("nothing running: dead channel, got %q", got)
	}
	a, b := ended("success", 1, 0, 0, 0, 60), ended("success", 1, 0, 0, 0, 60)
	b.State.EndedAt = "2026-10-04T11:00:05Z"
	if got := FleetEgg([]*Run{a, b}, now.Add(-30*time.Minute)); !strings.Contains(got, "fist my bump") {
		t.Errorf("two landings five seconds apart, got %q", got)
	}
	useTheme(t, "space", false)
	if RunEgg(ended("success", 42, 0, 0, 0, 60), now) != "" {
		t.Error("no eggs when they are off")
	}
}

func TestHyperspaceKey(t *testing.T) {
	useTheme(t, "space", true)
	m := newModel([]string{t.TempDir()}, false, time.Now)
	send(m, tea80x20())
	for _, k := range []string{"up", "up", "down", "down", "left", "right", "left", "right", "b"} {
		m.hyperspace(k)
	}
	if m.warp != 0 {
		t.Fatal("not yet")
	}
	if !m.hyperspace("a") || m.warp == 0 {
		t.Fatal("the full sequence jumps to hyperspace")
	}
	if !strings.Contains(plain(m.render()), "HYPERSPACE") {
		t.Errorf("the band shows the jump:\n%s", plain(m.render()))
	}
}
