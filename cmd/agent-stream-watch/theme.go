package main

// Themes: design files that restyle the watcher and the Bash pane, which
// read the same files. The base look lives here and matches the pane's
// quiet palette exactly; a theme file overrides only what it names. The
// format is documented in themes/README.md and the project setup in
// docs/spec-themes.md. Themes never change what is recorded.

import (
	"encoding/json"
	"errors"
	"fmt"
	"image/color"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/colorprofile"
)

const (
	themeSchema   = "agent-stream/theme/1"
	projectSchema = "agent-stream/project/1"
)

// Loudness levels from a project's .agent-stream/config.json.
const (
	Loud     = "loud"
	Balanced = "balanced"
	Quiet    = "quiet"
)

// Words is every piece of text a theme can change.
type Words struct {
	Tool, Done, Error, Warn, Note, Think, Wait, Step, Plan, Run, ResultOK string
	Altitude, Quiet, FleetTitle, ReportTitle                              string
	Header, States, Report, Columns                                       map[string]string
}

// Features switches the theme's extra drawing on and off.
type Features struct {
	Callsigns, LaunchHeader, MissionReport, Twinkle, HoldingSpinner bool
	Background                                                      string // stars, trails, grid, meters, belt, or "" for none
	Density                                                         int
	Gauge                                                           string // trajectory, exposure, dimension, fill, or "" for "d/N"
}

// Theme is a resolved theme: the base with a file's overrides applied, for
// one color profile and one loudness.
type Theme struct {
	Name     string
	Loudness string
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
		Name:     "base",
		Loudness: Quiet,
		Uni:      uni,
		Asc:      asc,
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
		Features: Features{Density: 9},
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

// Animated reports whether the theme may move at the tick.
func (t *Theme) Animated() bool { return t.Loudness == Loud }

// ------------------------------------------------------------- resolution --

// Choice is what selects a theme: an explicit spec (flag or
// AGENT_STREAM_THEME), else the project's config, else space.
type Choice struct {
	Theme, Loudness string
	Eggs            *bool  // project override of the theme's eggs_default
	ProjectDir      string // git top level holding .agent-stream/, or ""
}

// ProjectChoice reads .agent-stream/config.json at the git top level of dir.
// A missing file is not an error; a broken one is.
func ProjectChoice(dir string) (Choice, error) {
	top := gitTop(dir)
	if top == "" {
		return Choice{}, nil
	}
	data, err := os.ReadFile(filepath.Join(top, ".agent-stream", "config.json"))
	if err != nil {
		return Choice{ProjectDir: top}, nil
	}
	var c struct {
		Schema, Theme, Loudness string
		Eggs                    *bool
	}
	if err := json.Unmarshal(data, &c); err != nil {
		return Choice{ProjectDir: top}, fmt.Errorf(".agent-stream/config.json: %w", err)
	}
	if c.Schema != "" && c.Schema != projectSchema {
		return Choice{ProjectDir: top}, fmt.Errorf(".agent-stream/config.json: schema %q, want %q", c.Schema, projectSchema)
	}
	return Choice{Theme: clean(c.Theme), Loudness: clean(c.Loudness), Eggs: c.Eggs, ProjectDir: top}, nil
}

func gitTop(dir string) string {
	if dir == "" {
		return ""
	}
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// ResolveTheme picks and loads the theme. The terminal has the last word:
// no color, or ASCII marks, means the base look whatever was asked for.
// An explicit spec that cannot be loaded falls back to the base and returns
// the error so the caller can warn; the default (space) falls back quietly.
func ResolveTheme(c Choice, profile colorprofile.Profile, ascii, noEggs bool) (*Theme, error) {
	loud := c.Loudness
	switch loud {
	case Loud, Balanced, Quiet:
	case "":
		loud = Loud
	default:
		return Base(), fmt.Errorf("loudness %q: want loud, balanced, or quiet", loud)
	}
	colorOn := profile != colorprofile.NoTTY && profile != colorprofile.Ascii
	if !colorOn || ascii || loud == Quiet {
		return Base(), nil
	}
	spec := strings.TrimSpace(c.Theme)
	quietFallback := spec == "" || spec == "auto"
	if quietFallback {
		spec = "space"
	}
	if spec == "plain" || spec == "base" {
		return Base(), nil
	}
	path, err := findTheme(spec, c.ProjectDir)
	if err != nil {
		if quietFallback {
			return Base(), nil
		}
		return Base(), err
	}
	t, eggsDefault, err := LoadTheme(path, profile)
	if err != nil {
		return Base(), err
	}
	t.Loudness = loud
	eggs := eggsDefault
	if c.Eggs != nil {
		eggs = *c.Eggs
	}
	if !eggs || noEggs || loud != Loud || os.Getenv("AGENT_STREAM_EGGS") == "0" {
		t.Eggs = nil
	}
	return t, nil
}

// ThemeDirs is the search path for theme names after the project's own
// .agent-stream/ folder.
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

// findTheme resolves a theme spec to a file. "project" means the project's
// .agent-stream/theme.json. A name is looked up in the project first (its
// own NAME.json, or a theme.json whose name matches), then ThemeDirs.
func findTheme(spec, projectDir string) (string, error) {
	if strings.ContainsRune(spec, '/') || strings.HasSuffix(spec, ".json") {
		if _, err := os.Stat(spec); err != nil {
			return "", fmt.Errorf("theme file %s: %w", spec, err)
		}
		return spec, nil
	}
	if projectDir != "" {
		own := filepath.Join(projectDir, ".agent-stream", "theme.json")
		if spec == "project" {
			if _, err := os.Stat(own); err != nil {
				return "", fmt.Errorf("theme \"project\": %w", err)
			}
			return own, nil
		}
		if p := filepath.Join(projectDir, ".agent-stream", spec+".json"); fileExists(p) {
			return p, nil
		}
		if themeNameIs(own, spec) {
			return own, nil
		}
	}
	for _, d := range ThemeDirs() {
		if p := filepath.Join(d, spec+".json"); fileExists(p) {
			return p, nil
		}
	}
	return "", fmt.Errorf("theme %q not found in the project or %s", spec, strings.Join(ThemeDirs(), ", "))
}

func fileExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

func themeNameIs(path, name string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var f struct{ Name string }
	return json.Unmarshal(data, &f) == nil && f.Name == name
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
	Schema      string                       `json:"schema"`
	Name        string                       `json:"name"`
	Colors      map[string]json.RawMessage   `json:"colors"`
	Glyphs      map[string]map[string]string `json:"glyphs"`
	Words       map[string]json.RawMessage   `json:"words"`
	Features    map[string]json.RawMessage   `json:"features"`
	Background  json.RawMessage              `json:"background"`
	Gauge       string                       `json:"gauge"`
	EggsDefault *bool                        `json:"eggs_default"`
	Calls       struct {
		Names []string `json:"names"`
	} `json:"callsigns"`
	Eggs map[string]string `json:"eggs"`
}

var backgroundKinds = map[string]bool{"": true, "none": true, "stars": true, "trails": true, "grid": true, "meters": true, "belt": true}
var gaugeKinds = map[string]bool{"": true, "trajectory": true, "exposure": true, "dimension": true, "fill": true}

// LoadTheme reads a theme file and applies it over the base for a color
// profile. It also returns whether the theme wants eggs by default.
func LoadTheme(path string, profile colorprofile.Profile) (*Theme, bool, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, false, err
	}
	var f themeFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, false, fmt.Errorf("theme %s: %w", path, err)
	}
	if f.Schema != themeSchema {
		return nil, false, fmt.Errorf("theme %s: schema %q, want %q", path, f.Schema, themeSchema)
	}
	t := Base()
	t.Name = clean(f.Name)
	if t.Name == "" {
		t.Name = strings.TrimSuffix(filepath.Base(path), ".json")
	}
	pick := lipgloss.Complete(profile)
	for role, raw := range f.Colors {
		if role == "ships" {
			var list []colorSpec
			if err := json.Unmarshal(raw, &list); err != nil {
				return nil, false, fmt.Errorf("theme %s: colors.ships: %w", path, err)
			}
			for _, c := range list {
				t.ships = append(t.ships, styleFor(c, pick))
			}
			continue
		}
		var c colorSpec
		if err := json.Unmarshal(raw, &c); err != nil {
			return nil, false, fmt.Errorf("theme %s: colors.%s: %w", path, role, err)
		}
		s := styleFor(c, pick)
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
		return nil, false, fmt.Errorf("theme %s: words: %w", path, err)
	}
	if err := applyFeatures(&t.Features, f.Features); err != nil {
		return nil, false, fmt.Errorf("theme %s: features: %w", path, err)
	}
	if len(f.Background) > 0 {
		var bg struct {
			Kind    string `json:"kind"`
			Density int    `json:"density"`
		}
		if err := json.Unmarshal(f.Background, &bg); err != nil {
			return nil, false, fmt.Errorf("theme %s: background: %w", path, err)
		}
		if !backgroundKinds[bg.Kind] {
			return nil, false, fmt.Errorf("theme %s: background kind %q", path, bg.Kind)
		}
		if bg.Kind == "none" {
			bg.Kind = ""
		}
		t.Features.Background = bg.Kind
		if bg.Density >= 2 {
			t.Features.Density = bg.Density
		}
	}
	if !gaugeKinds[f.Gauge] {
		return nil, false, fmt.Errorf("theme %s: gauge %q", path, f.Gauge)
	}
	t.Features.Gauge = f.Gauge
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
	eggsDefault := true
	if f.EggsDefault != nil {
		eggsDefault = *f.EggsDefault
	}
	return t, eggsDefault, nil
}

// styleFor turns a color spec into a style for the profile: the theme's own
// 16-color and 256-color choices, not an automatic conversion, so a theme
// looks as designed on every terminal.
func styleFor(c colorSpec, pick lipgloss.CompleteFunc) lipgloss.Style {
	s := lipgloss.NewStyle()
	var ansi16, ansi256, truecolor color.Color
	if c.ANSI != nil && *c.ANSI >= 0 && *c.ANSI <= 15 {
		ansi16 = lipgloss.Color(fmt.Sprint(*c.ANSI))
	}
	if c.ANSI256 != nil && *c.ANSI256 >= 0 && *c.ANSI256 <= 255 {
		ansi256 = lipgloss.Color(fmt.Sprint(*c.ANSI256))
	} else {
		ansi256 = ansi16
	}
	if c.Hex != "" {
		truecolor = lipgloss.Color(c.Hex)
	} else {
		truecolor = ansi256
	}
	if fg := pick(ansi16, ansi256, truecolor); fg != nil {
		s = s.Foreground(fg)
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
	set := map[string]*string{
		"active": &m.active, "step": &m.step, "done": &m.done, "error": &m.err, "warn": &m.warn,
		"unknown": &m.unknown, "pending": &m.pending, "wait": &m.wait, "dropped": &m.drop,
		"sep": &m.sep, "ell": &m.ell, "card_open": &m.cardOpen, "card_close": &m.cardClose,
		"rule": &m.h, "side": &m.v, "divider": &m.h2, "lit": &m.lit, "launch": &m.launch,
		"trail": &m.trail, "ahead": &m.ahead, "sky": &m.sky, "orbit": &m.orbit, "field": &m.field,
	}
	for k, v := range g {
		if dst, ok := set[k]; ok {
			*dst = clean(v)
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
		"callsigns": &f.Callsigns, "launch_header": &f.LaunchHeader, "mission_report": &f.MissionReport,
		"twinkle": &f.Twinkle, "holding_spinner": &f.HoldingSpinner,
	}
	for k, v := range raw {
		if dst, ok := bools[k]; ok {
			if err := json.Unmarshal(v, dst); err != nil {
				return fmt.Errorf("%s: %w", k, err)
			}
			continue
		}
		return errors.New("unknown feature " + k)
	}
	return nil
}

// ------------------------------------------------------------- callsigns --

// djb2 is the hash the watcher and the pane share for callsigns and
// backgrounds, over the bytes of a string, kept to 32 bits.
func djb2(s string) uint32 {
	h := uint32(5381)
	for i := 0; i < len(s); i++ {
		h = h*33 + uint32(s[i])
	}
	return h
}

// Callsign is NAME-D for a run id, or "" when the theme has no callsigns.
// The callsign_1701 egg replaces it for an id containing 1701.
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

// -------------------------------------------------------- background math --

// lcg is the small generator both the watcher and the pane use, so a
// seeded background looks the same in both.
func lcg(x uint32) uint32 { return x*1103515245 + 12345 }

// Background is one row of the theme's generated backdrop, width columns
// wide. seed fixes the layout, frame moves it (only when the theme is loud),
// and level (0 to 1) is the live quantity the generator follows: elapsed
// time for trails, activity for meters, finished work for the belt.
func (t *Theme) Background(m marks, width, row int, seed uint32, frame int, level float64) string {
	glyphs := []rune(m.sky)
	if t.Features.Background == "" || len(glyphs) == 0 || width <= 0 {
		return ""
	}
	if !t.Animated() {
		frame = 0
	}
	if level < 0 {
		level = 0
	}
	if level > 1 {
		level = 1
	}
	density := uint32(t.Features.Density)
	if density < 2 {
		density = 9
	}
	cells := make([]rune, width)
	for i := range cells {
		cells[i] = ' '
	}
	field := []rune(m.field)
	x := seed ^ uint32(row)*2654435761 | 1
	switch t.Features.Background {
	case "stars", "trails":
		tail := 0
		if t.Features.Background == "trails" {
			tail = int(level*6) + 1
		}
		for col := 0; col < width; col++ {
			x = lcg(x)
			r := x >> 8
			if r%density != 0 {
				continue
			}
			g := int((r >> 8) % uint32(len(glyphs)))
			if t.Features.Twinkle && (r>>4)%3 == 0 {
				g = (g + frame) % len(glyphs)
			}
			pos := col
			if tail > 0 {
				pos = (col + frame/2) % width
				for k := 1; k <= tail && len(field) > 0; k++ {
					if p := pos - k; p >= 0 && cells[p] == ' ' {
						cells[p] = field[0]
					}
				}
			}
			cells[pos] = glyphs[g]
		}
	case "grid":
		step := int(density)
		for col := 0; col < width; col++ {
			// Graph paper: crosses where major lines meet, dots along the
			// minor lines, and a dot on every row of each major column.
			switch {
			case row%2 == 0 && col%(step*2) == 0 && len(glyphs) > 1:
				cells[col] = glyphs[1]
			case row%2 == 0 && col%step == 0:
				cells[col] = glyphs[0]
			case col%(step*2) == 0:
				cells[col] = glyphs[0]
			}
		}
	case "meters":
		bars := []rune(m.field)
		if len(bars) == 0 {
			bars = glyphs
		}
		for col := 0; col < width; col += 2 {
			x = lcg(x ^ uint32(col))
			wobble := float64((x>>8)%100) / 100
			h := level*0.75 + wobble*0.25
			if t.Animated() {
				h = level*0.6 + 0.4*math.Abs(math.Sin(float64(frame+col)/3))*wobble
			}
			idx := int(h * float64(len(bars)-1))
			if idx > 0 {
				cells[col] = bars[idx]
			}
		}
	case "belt":
		step := int(density)
		filled := int(level * float64(width/step))
		for col := 0; col < width; col++ {
			if len(field) > 0 {
				cells[col] = field[0]
			}
		}
		for i := 0; i*step < width; i++ {
			col := (i*step + frame) % width
			if i < filled && len(glyphs) > 1 {
				cells[col] = glyphs[1]
			} else {
				cells[col] = glyphs[0]
			}
		}
	}
	return stSky.Render(string(cells))
}

// ------------------------------------------------------------------ gauges --

// Gauge draws plan progress the theme's way, at most max columns. statuses
// are the plan's item states in order.
func (t *Theme) Gauge(m marks, statuses []string, seg, max int) string {
	n := len(statuses)
	if n == 0 {
		return ""
	}
	done := 0
	active := false
	for _, s := range statuses {
		switch s {
		case "done", "dropped":
			done++
		case "active":
			active = true
		}
	}
	switch t.Features.Gauge {
	case "trajectory":
		return t.trajectory(m, statuses, seg, max)
	case "exposure":
		w := clamp(max, 4, 24)
		shades := []rune(m.field)
		if len(shades) < 2 {
			shades = []rune(" .:#")
		}
		fill := float64(done) / float64(n) * float64(w)
		var b strings.Builder
		for i := 0; i < w; i++ {
			d := fill - float64(i)
			switch {
			case d >= 1:
				b.WriteRune(shades[len(shades)-1])
			case d > 0:
				b.WriteRune(shades[int(d*float64(len(shades)-1))])
			default:
				b.WriteRune(shades[0])
			}
		}
		return stOK.Render(b.String())
	case "dimension":
		label := fmt.Sprintf(" %d of %d ", done, n)
		w := clamp(max, len(label)+4, 40)
		side := (w - len(label) - 2) / 2
		if side < 1 {
			side = 1
		}
		return stHead.Render("|<" + strings.Repeat(m.trail, side-1) + label + strings.Repeat(m.trail, w-len(label)-2-side-1) + ">|")
	case "fill":
		w := clamp(max, 5, 16)
		inner := w - 2
		f := done * inner / n
		bar := strings.Repeat(m.lit, f) + strings.Repeat(m.pending, inner-f)
		cap := m.cardOpen
		if cap == "" {
			cap = "["
		}
		end := m.cardClose
		if end == "" {
			end = "]"
		}
		st := stOK
		if active {
			st = stHead
		}
		return stDim.Render(cap) + st.Render(bar) + stDim.Render(end)
	}
	return fmt.Sprintf("%d/%d", done, n)
}

func (t *Theme) trajectory(m marks, statuses []string, seg, max int) string {
	n := len(statuses)
	if m.lit == "" {
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
