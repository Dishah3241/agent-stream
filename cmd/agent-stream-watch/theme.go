package main

// Themes: design files that restyle the watcher (and the Bash pane, which
// reads the same files). The base look lives in this file and matches the
// pane's quiet palette exactly; a theme file overrides only what it names.
// The format is documented in themes/README.md. Themes never change what is
// recorded: they only change how the watcher draws it.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

const themeSchema = "agent-stream/theme/1"

// Words is every piece of text a theme can change.
type Words struct {
	Tool, Done, Error, Warn, Note, Think, Wait, Step, Plan, Run, ResultOK string
	Altitude, Quiet, FleetTitle, ReportTitle                             string
	Header                                                               map[string]string
	States                                                               map[string]string
	Report                                                               map[string]string
	Columns                                                              map[string]string
}

// Features switches the theme's extra drawing on and off.
type Features struct {
	Sky, Callsigns, Trajectory, LaunchHeader, MissionReport, Twinkle, HoldingSpinner bool
	SkyDensity                                                                       int
}

// Theme is a resolved theme: the base with a file's overrides applied.
type Theme struct {
	Name     string
	Uni, Asc marks
	Words    Words
	Features Features
	Names    []string
	Eggs     map[string]string // nil when eggs are off

	accent, dim, ok, warn, err, title, think, sky, egg lipgloss.Style
	ships                                              []lipgloss.Style
}

// cur is the theme in use. Tests and the base look use Base().
var cur = Base()

// Base is the look without a theme file: the pane's 16-color palette,
// marks, and words.
func Base() *Theme {
	t := &Theme{
		Name: "base",
		Uni:  uni,
		Asc:  asc,
		Words: Words{
			Think: "think", Wait: "waiting", Step: "now", Plan: "plan", Run: "run",
			Altitude: "plan", Quiet: "quiet", FleetTitle: "agent-stream",
			Header: map[string]string{"task": "task", "cwd": "cwd", "agent": "run", "output": "output", "liftoff": ""},
			States: map[string]string{
				"running": "running", "waiting": "waiting", "starting": "starting",
				"success": "success", "failed": "failed", "error": "error",
				"cancelled": "cancelled", "exited": "exited", "ended": "ended", "unknown": "unknown",
			},
			Report: map[string]string{
				"success": "done", "failed": "failed", "error": "failed",
				"cancelled": "cancelled", "exited": "exited", "ended": "ended",
			},
			Columns: map[string]string{
				"ship": "", "state": "STATE", "project": "PROJECT", "agent": "AGENT",
				"plan": "PLAN", "elapsed": "ELAPSED", "now": "NOW",
			},
		},
		Features: Features{SkyDensity: 9},
		accent:   lipgloss.NewStyle().Foreground(lipgloss.Color("6")),
		dim:      lipgloss.NewStyle().Faint(true),
		ok:       lipgloss.NewStyle().Foreground(lipgloss.Color("2")),
		warn:     lipgloss.NewStyle().Foreground(lipgloss.Color("3")),
		err:      lipgloss.NewStyle().Foreground(lipgloss.Color("1")),
		title:    lipgloss.NewStyle().Bold(true),
	}
	t.think, t.sky, t.egg = t.dim, t.dim, t.accent
	return t
}

// Use makes t the theme in use and points the package styles at it.
func Use(t *Theme) {
	cur = t
	stHead, stDim, stOK, stWarn, stErr = t.accent, t.dim, t.ok, t.warn, t.err
	stBold = t.title
	stThink, stSky, stEgg = t.think, t.sky, t.egg
}

// Marks returns the theme's glyph set for the terminal.
func (t *Theme) Marks(ascii bool) marks {
	if ascii {
		return t.Asc
	}
	return t.Uni
}

// State is the theme's word for a run state.
func (t *Theme) State(key string) string {
	if w, ok := t.Words.States[key]; ok {
		return w
	}
	return key
}

// Egg returns an egg's text, or "" when eggs are off or the theme has none.
func (t *Theme) Egg(id string) string {
	if t.Eggs == nil {
		return ""
	}
	return t.Eggs[id]
}

// ------------------------------------------------------------- resolution --

// ResolveTheme picks the theme for a spec ("" or auto, plain, a name, a
// path). colorOn and ascii describe the terminal; auto means space on a
// color, UTF-8 terminal and the base everywhere else. A theme that cannot be
// loaded falls back to the base; the error is returned so the caller can
// warn, except for auto, which falls back silently.
func ResolveTheme(spec string, colorOn, ascii, eggs bool) (*Theme, error) {
	spec = strings.TrimSpace(spec)
	auto := spec == "" || spec == "auto"
	if auto {
		if !colorOn || ascii {
			return Base(), nil
		}
		spec = "space"
	}
	if spec == "plain" || spec == "base" {
		return Base(), nil
	}
	path, err := findTheme(spec)
	if err != nil {
		if auto {
			return Base(), nil
		}
		return Base(), err
	}
	t, err := LoadTheme(path)
	if err != nil {
		return Base(), err
	}
	if !eggs || !colorOn || ascii {
		t.Eggs = nil
	}
	return t, nil
}

// ThemeDirs is the search path for theme names.
func ThemeDirs() []string {
	var dirs []string
	for _, d := range strings.Split(os.Getenv("AGENT_STREAM_THEMES"), ":") {
		if d != "" {
			dirs = append(dirs, d)
		}
	}
	if h, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(h, ".config", "agent-stream", "themes"))
	}
	if exe, err := os.Executable(); err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		d := filepath.Dir(exe)
		dirs = append(dirs, filepath.Join(d, "..", "themes"), filepath.Join(d, "..", "..", "themes"))
	}
	return dirs
}

func findTheme(spec string) (string, error) {
	if strings.ContainsRune(spec, '/') || strings.HasSuffix(spec, ".json") {
		if _, err := os.Stat(spec); err != nil {
			return "", fmt.Errorf("theme file %s: %w", spec, err)
		}
		return spec, nil
	}
	for _, d := range ThemeDirs() {
		p := filepath.Join(d, spec+".json")
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	return "", fmt.Errorf("theme %q not found in %s", spec, strings.Join(ThemeDirs(), ", "))
}

// ---------------------------------------------------------------- loading --

type colorSpec struct {
	Hex     string `json:"hex"`
	ANSI256 *int   `json:"ansi256"`
	ANSI    *int   `json:"ansi"`
	Bold    bool   `json:"bold"`
	Faint   bool   `json:"faint"`
}

type themeFile struct {
	Schema   string                       `json:"schema"`
	Name     string                       `json:"name"`
	Colors   map[string]json.RawMessage   `json:"colors"`
	Glyphs   map[string]map[string]string `json:"glyphs"`
	Words    map[string]json.RawMessage   `json:"words"`
	Features map[string]json.RawMessage   `json:"features"`
	Calls    struct {
		Names []string `json:"names"`
	} `json:"callsigns"`
	Eggs map[string]string `json:"eggs"`
}

// LoadTheme reads a theme file and applies it over the base.
func LoadTheme(path string) (*Theme, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f themeFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("theme %s: %w", path, err)
	}
	if f.Schema != "" && f.Schema != themeSchema {
		return nil, fmt.Errorf("theme %s: schema %q, want %q", path, f.Schema, themeSchema)
	}
	t := Base()
	t.Name = clean(f.Name)
	if t.Name == "" {
		t.Name = strings.TrimSuffix(filepath.Base(path), ".json")
	}
	for role, raw := range f.Colors {
		if role == "ships" {
			var list []colorSpec
			if err := json.Unmarshal(raw, &list); err != nil {
				return nil, fmt.Errorf("theme %s: colors.ships: %w", path, err)
			}
			for _, c := range list {
				t.ships = append(t.ships, styleFor(c))
			}
			continue
		}
		var c colorSpec
		if err := json.Unmarshal(raw, &c); err != nil {
			return nil, fmt.Errorf("theme %s: colors.%s: %w", path, role, err)
		}
		s := styleFor(c)
		switch role {
		case "accent":
			t.accent = s
		case "dim":
			t.dim = s
		case "ok":
			t.ok = s
		case "warn":
			t.warn = s
		case "err":
			t.err = s
		case "title":
			t.title = s
		case "think":
			t.think = s
		case "sky":
			t.sky = s
		case "egg":
			t.egg = s
		}
	}
	applyGlyphs(&t.Uni, f.Glyphs["unicode"])
	applyGlyphs(&t.Asc, f.Glyphs["ascii"])
	if err := applyWords(&t.Words, f.Words); err != nil {
		return nil, fmt.Errorf("theme %s: words: %w", path, err)
	}
	if err := applyFeatures(&t.Features, f.Features); err != nil {
		return nil, fmt.Errorf("theme %s: features: %w", path, err)
	}
	for _, n := range f.Calls.Names {
		if n = clean(n); n != "" {
			t.Names = append(t.Names, n)
		}
	}
	if len(f.Eggs) > 0 {
		t.Eggs = map[string]string{}
		for k, v := range f.Eggs {
			t.Eggs[k] = clean(v)
		}
	}
	return t, nil
}

// styleFor turns a color spec into a style: a full color with true-color,
// 256-color, and 16-color values, or a plain 16-color index, plus bold and
// faint. Lip Gloss drops color by itself when the profile has none.
func styleFor(c colorSpec) lipgloss.Style {
	s := lipgloss.NewStyle()
	ansi16 := ""
	if c.ANSI != nil && *c.ANSI >= 0 && *c.ANSI <= 15 {
		ansi16 = strconv.Itoa(*c.ANSI)
	}
	switch {
	case c.Hex != "":
		cc := lipgloss.CompleteColor{TrueColor: c.Hex, ANSI: ansi16}
		if c.ANSI256 != nil && *c.ANSI256 >= 0 && *c.ANSI256 <= 255 {
			cc.ANSI256 = strconv.Itoa(*c.ANSI256)
		} else {
			cc.ANSI256 = ansi16
		}
		s = s.Foreground(cc)
	case ansi16 != "":
		s = s.Foreground(lipgloss.Color(ansi16))
	}
	if c.Bold {
		s = s.Bold(true)
	}
	if c.Faint {
		s = s.Faint(true)
	}
	return s
}

func applyGlyphs(m *marks, g map[string]string) {
	for k, v := range g {
		v = clean(v)
		switch k {
		case "active":
			m.active = v
		case "step":
			m.step = v
		case "done":
			m.done = v
		case "error":
			m.err = v
		case "warn":
			m.warn = v
		case "unknown":
			m.unknown = v
		case "pending":
			m.pending = v
		case "wait":
			m.wait = v
		case "dropped":
			m.drop = v
		case "sep":
			m.sep = v
		case "ell":
			m.ell = v
		case "card_open":
			m.cardOpen = v
		case "card_close":
			m.cardClose = v
		case "rule":
			m.h = v
		case "side":
			m.v = v
		case "divider":
			m.h2 = v
		case "lit":
			m.lit = v
		case "launch":
			m.launch = v
		case "trail":
			m.trail = v
		case "ahead":
			m.ahead = v
		case "sky":
			m.sky = v
		case "orbit":
			m.orbit = v
		}
	}
}

func applyWords(w *Words, raw map[string]json.RawMessage) error {
	maps := map[string]map[string]string{"header": w.Header, "states": w.States, "report": w.Report, "columns": w.Columns}
	strs := map[string]*string{
		"tool": &w.Tool, "done": &w.Done, "error": &w.Error, "warn": &w.Warn, "note": &w.Note,
		"think": &w.Think, "wait": &w.Wait, "step": &w.Step, "plan": &w.Plan, "run": &w.Run,
		"result_ok": &w.ResultOK, "altitude": &w.Altitude, "quiet": &w.Quiet,
		"fleet_title": &w.FleetTitle, "report_title": &w.ReportTitle,
	}
	for k, v := range raw {
		if dst, ok := maps[k]; ok {
			var m map[string]string
			if err := json.Unmarshal(v, &m); err != nil {
				return fmt.Errorf("%s: %w", k, err)
			}
			for mk, mv := range m {
				dst[mk] = clean(mv)
			}
			continue
		}
		if dst, ok := strs[k]; ok {
			var s string
			if err := json.Unmarshal(v, &s); err != nil {
				return fmt.Errorf("%s: %w", k, err)
			}
			*dst = clean(s)
		}
	}
	return nil
}

func applyFeatures(f *Features, raw map[string]json.RawMessage) error {
	bools := map[string]*bool{
		"sky": &f.Sky, "callsigns": &f.Callsigns, "trajectory": &f.Trajectory,
		"launch_header": &f.LaunchHeader, "mission_report": &f.MissionReport,
		"twinkle": &f.Twinkle, "holding_spinner": &f.HoldingSpinner,
	}
	for k, v := range raw {
		if dst, ok := bools[k]; ok {
			if err := json.Unmarshal(v, dst); err != nil {
				return fmt.Errorf("%s: %w", k, err)
			}
			continue
		}
		if k == "sky_density" {
			var n int
			if err := json.Unmarshal(v, &n); err != nil {
				return fmt.Errorf("%s: %w", k, err)
			}
			if n < 2 {
				return errors.New("sky_density must be 2 or more")
			}
			f.SkyDensity = n
		}
	}
	return nil
}

// --------------------------------------------------------------- drawing --

// djb2 is the hash both the watcher and the pane use for callsigns and the
// sky, over the bytes of the run id, kept to 32 bits.
func djb2(s string) uint32 {
	h := uint32(5381)
	for i := 0; i < len(s); i++ {
		h = h*33 + uint32(s[i])
	}
	return h
}

// Callsign is NAME-D for a run id, or "" when the theme has no callsigns.
// The ENTERPRISE egg replaces it for an id containing 1701.
func (t *Theme) Callsign(id string) string {
	if !t.Features.Callsigns || len(t.Names) == 0 || id == "" {
		return ""
	}
	if e := t.Egg("callsign_1701"); e != "" && strings.Contains(id, "1701") {
		return e
	}
	h := djb2(id)
	n := uint32(len(t.Names))
	return fmt.Sprintf("%s-%d", t.Names[h%n], (h/n)%9+1)
}

// ShipStyle is the stable color for a run's callsign.
func (t *Theme) ShipStyle(id string) lipgloss.Style {
	if len(t.ships) == 0 {
		return t.accent
	}
	return t.ships[djb2(id)%uint32(len(t.ships))]
}

// Sky is one row of stars, width columns wide, seeded so a row looks the
// same on every redraw. frame twinkles about a third of the stars. Returns
// "" when the theme has no sky or the marks have no star glyphs.
func (t *Theme) Sky(m marks, width int, seed uint32, frame int) string {
	glyphs := []rune(m.sky)
	if !t.Features.Sky || len(glyphs) == 0 || width <= 0 {
		return ""
	}
	density := uint32(t.Features.SkyDensity)
	if density < 2 {
		density = 9
	}
	x := seed | 1
	var b strings.Builder
	for col := 0; col < width; col++ {
		x = x*1103515245 + 12345
		r := x >> 8
		if r%density != 0 {
			b.WriteByte(' ')
			continue
		}
		g := int((r >> 8) % uint32(len(glyphs)))
		if t.Features.Twinkle && (r>>4)%3 == 0 {
			g = (g + frame) % len(glyphs)
		}
		b.WriteString(stSky.Render(string(glyphs[g])))
	}
	return b.String()
}

// Trajectory draws a plan as a flight path: lit stars for finished items,
// the rocket on the active one, dots ahead, a cross for dropped ones, joined
// by a burn trail behind the rocket and a dotted course ahead of it. seg is
// the connector length; when the path would be wider than max it becomes a
// proportional bar.
func (t *Theme) Trajectory(m marks, statuses []string, seg, max int) string {
	n := len(statuses)
	if n == 0 || m.lit == "" {
		return ""
	}
	if seg < 0 {
		seg = 0
	}
	if n+(n-1)*seg > max && max > 2 {
		done := 0
		for _, s := range statuses {
			if s == "done" || s == "dropped" {
				done++
			}
		}
		filled := done * (max - 1) / n
		bar := stOK.Render(strings.Repeat(m.trail, filled))
		if done < n {
			bar += stHead.Render(m.active) + stDim.Render(strings.Repeat(m.ahead, max-1-filled))
		} else {
			bar += stOK.Render(m.lit)
		}
		return bar
	}
	var b strings.Builder
	for i, s := range statuses {
		switch s {
		case "done":
			b.WriteString(stOK.Render(m.lit))
		case "active":
			b.WriteString(stHead.Render(m.active))
		case "dropped":
			b.WriteString(stDim.Render(m.drop))
		default:
			b.WriteString(stDim.Render(m.pending))
		}
		if i == n-1 {
			break
		}
		if s == "done" {
			b.WriteString(stOK.Render(strings.Repeat(m.trail, seg)))
		} else {
			b.WriteString(stDim.Render(strings.Repeat(m.ahead, seg)))
		}
	}
	return b.String()
}
