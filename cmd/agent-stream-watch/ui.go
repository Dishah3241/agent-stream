package main

// The Bubble Tea model: a fleet view (one row per run) and a run view
// (pinned header, optional plan panel, the display in a scrolling viewport,
// pinned footer). A tick every second re-reads what changed: state.json
// files whose mtime moved, and new bytes at the end of the open run's
// display.txt. Nothing here writes to a record.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// recentEnded is how many ended runs the fleet lists until `a` shows all.
const recentEnded = 10

// quietAfter is how long an open run's state may stay unchanged before the
// fleet and the footer say how long it has been quiet.
const quietAfter = 2 * time.Minute

type tickMsg time.Time

func tick() tea.Cmd {
	return tea.Tick(time.Second, func(t time.Time) tea.Msg { return tickMsg(t) })
}

type mode int

const (
	fleetMode mode = iota
	runMode
)

type model struct {
	roots    []string
	runs     []*Run
	allEnded bool
	sel      string // selected run directory in the fleet
	top      int    // first fleet row shown
	mode     mode
	width    int
	height   int
	now      func() time.Time
	ascii    bool
	mk       marks

	// The open run.
	dir      string
	rend     *Renderer
	raw      []string // protocol lines read so far
	styled   []string // rendered, unwrapped
	wrapped  []string // rendered and wrapped to the viewport width
	offset   int64
	partial  string
	tailErr  error
	vp       viewport.Model
	showPlan bool
	markdown bool
}

func newModel(roots []string, ascii bool, now func() time.Time) *model {
	m := &model{roots: roots, ascii: ascii, now: now, showPlan: true}
	m.mk = uni
	if ascii {
		m.mk = asc
	}
	m.vp = viewport.New(0, 0)
	m.runs = Refresh(nil, roots, now())
	if v := m.visible(); len(v) > 0 {
		m.sel = v[0].Dir
	}
	return m
}

func (m *model) Init() tea.Cmd { return tick() }

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		if m.mode == runMode {
			m.layout()
			if m.markdown {
				m.rerender()
			} else {
				m.rewrapAll()
			}
			m.setContent(false)
		}
		return m, nil
	case tickMsg:
		m.refresh()
		return m, tick()
	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			return m, tea.Quit
		}
		if m.mode == fleetMode {
			return m.fleetKey(msg)
		}
		return m.runKey(msg)
	}
	return m, nil
}

func (m *model) View() string {
	if m.width <= 0 || m.height <= 0 {
		return ""
	}
	if m.mode == runMode {
		return m.runView()
	}
	return m.fleetView()
}

// refresh re-reads the roots and, in the run view, the open display.txt.
func (m *model) refresh() {
	m.runs = Refresh(m.runs, m.roots, m.now())
	if m.mode == runMode {
		m.layout()
		m.pull(false)
	}
}

// ------------------------------------------------------------------ fleet --

// visible is the fleet's rows: every open run, then the most recent ended
// runs (all of them after `a`).
func (m *model) visible() []*Run {
	var out []*Run
	ended := 0
	for _, r := range m.runs {
		if r.Open() {
			out = append(out, r)
			continue
		}
		if !m.allEnded && ended >= recentEnded {
			continue
		}
		ended++
		out = append(out, r)
	}
	return out
}

func (m *model) cursor(rows []*Run) int {
	for i, r := range rows {
		if r.Dir == m.sel {
			return i
		}
	}
	return 0
}

func (m *model) fleetKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	rows := m.visible()
	c := m.cursor(rows)
	switch k.String() {
	case "q", "esc":
		return m, tea.Quit
	case "j", "down":
		c++
	case "k", "up":
		c--
	case "g", "home":
		c = 0
	case "G", "end":
		c = len(rows) - 1
	case "pgdown", " ":
		c += m.fleetRows()
	case "pgup":
		c -= m.fleetRows()
	case "a":
		m.allEnded = !m.allEnded
		rows = m.visible()
		c = m.cursor(rows)
	case "r":
		m.refresh()
		rows = m.visible()
		c = m.cursor(rows)
	case "enter", "l", "right":
		if len(rows) > 0 {
			m.openRun(rows[clamp(c, 0, len(rows)-1)].Dir)
		}
		return m, nil
	}
	if len(rows) > 0 {
		m.sel = rows[clamp(c, 0, len(rows)-1)].Dir
	}
	return m, nil
}

// fleetRows is how many table rows fit: title, rule, column heads, rule,
// and one key line take five.
func (m *model) fleetRows() int {
	n := m.height - 5
	if n < 1 {
		n = 1
	}
	return n
}

func (m *model) fleetView() string {
	rows := m.visible()
	now := m.now()
	open := 0
	for _, r := range m.runs {
		if r.Open() {
			open++
		}
	}
	ended := len(m.runs) - open
	title := stBold.Render("agent-stream") + stDim.Render(fmt.Sprintf(" %s %d open %s %d ended %s %s",
		m.mk.sep, open, m.mk.sep, ended, m.mk.sep, tildeList(m.roots)))
	lines := []string{fit(title, m.width), m.rule(), fit(stDim.Render(FleetHead(m.width, true)), m.width)}

	body := FleetLines(rows, now, m.mk, m.width, m.sel, true)
	if len(rows) == 0 {
		body = []string{stDim.Render("  no runs yet under " + tildeList(m.roots)),
			stDim.Render("  start one with: agent-stream run --agent claude --task \"" + m.mk.ell + "\"")}
	}
	n := m.fleetRows()
	c := m.cursor(rows)
	if c < m.top {
		m.top = c
	}
	if c >= m.top+n {
		m.top = c - n + 1
	}
	if m.top > len(body)-n {
		m.top = len(body) - n
	}
	if m.top < 0 {
		m.top = 0
	}
	shown := body[m.top:]
	if len(shown) > n {
		shown = shown[:n]
	}
	for _, l := range shown {
		lines = append(lines, fit(l, m.width))
	}
	for len(lines) < m.height-2 {
		lines = append(lines, "")
	}
	which := fmt.Sprintf("a all ended (showing %d recent)", recentEnded)
	if m.allEnded {
		which = "a recent ended only"
	}
	keys := strings.Join([]string{"j/k move", "enter open", which, "r refresh", "q quit"}, " "+m.mk.sep+" ")
	lines = append(lines, m.rule(), fit(stDim.Render(keys), m.width))
	return strings.Join(lines, "\n")
}

// Column widths of the fleet table for a terminal width.
type columns struct{ state, project, agent, plan, elapsed, now int }

func fleetColumns(width int) columns {
	c := columns{state: 9, project: 24, agent: 22, plan: 5, elapsed: 7}
	if width < 110 {
		c.agent = 0
	}
	if width < 80 {
		c.project = 16
	}
	// prefix 2, mark 2, and one space after each column.
	used := 2 + 2 + c.state + 1 + c.project + 1 + c.plan + 1 + c.elapsed + 1
	if c.agent > 0 {
		used += c.agent + 1
	}
	c.now = width - used
	if c.now < 10 {
		c.now = 10
	}
	return c
}

// FleetHead is the column heading line of the fleet table.
func FleetHead(width int, prefix bool) string {
	c := fleetColumns(width)
	mk := asc
	var b strings.Builder
	if prefix {
		b.WriteString("  ")
	}
	b.WriteString("  ")
	b.WriteString(cell("STATE", c.state, mk) + " ")
	b.WriteString(cell("PROJECT", c.project, mk) + " ")
	if c.agent > 0 {
		b.WriteString(cell("AGENT", c.agent, mk) + " ")
	}
	b.WriteString(cell("PLAN", c.plan, mk) + " ")
	b.WriteString(cellRight("ELAPSED", c.elapsed, mk) + " ")
	b.WriteString("NOW")
	return b.String()
}

// FleetLines renders one line per run. sel marks the selected row when
// prefix is set (the interactive view); the printed table has no prefix.
func FleetLines(runs []*Run, now time.Time, mk marks, width int, sel string, prefix bool) []string {
	c := fleetColumns(width)
	var out []string
	for _, r := range runs {
		mark, st, word := runMark(r, mk)
		var b strings.Builder
		if prefix {
			if r.Dir == sel {
				b.WriteString(stHead.Render(mk.head) + " ")
			} else {
				b.WriteString("  ")
			}
		}
		b.WriteString(st.Render(mark) + " ")
		b.WriteString(st.Render(cell(word, c.state, mk)) + " ")
		label := cell(r.Label(mk.sep), c.project, mk)
		if prefix && r.Dir == sel {
			label = stBold.Render(label)
		}
		b.WriteString(label + " ")
		if c.agent > 0 {
			b.WriteString(stDim.Render(cell(agentModel(r), c.agent, mk)) + " ")
		}
		b.WriteString(cell(planCell(r), c.plan, mk) + " ")
		b.WriteString(cellRight(Duration(int64(r.Elapsed(now)/time.Second)), c.elapsed, mk) + " ")
		nowText := Shorten(quietPrefix(r, now, mk)+r.Now(), c.now, mk)
		if !r.Open() {
			nowText = stDim.Render(nowText)
		}
		b.WriteString(nowText)
		out = append(out, b.String())
	}
	return out
}

// runMark is a run's mark, its style, and one word for its state.
func runMark(r *Run, mk marks) (string, lipgloss.Style, string) {
	s := r.State
	switch {
	case s == nil:
		return mk.idle, stDim, "unknown"
	case s.Status == "ended":
		switch r.OutcomeKind() {
		case "success":
			return mk.done, stOK, "success"
		case "failed", "error":
			return mk.err, stErr, r.OutcomeKind()
		case "cancelled":
			return mk.warn, stWarn, "cancelled"
		case "":
			return mk.idle, stDim, "ended"
		default:
			return mk.idle, stDim, r.OutcomeKind()
		}
	case s.Waiting != nil || s.Status == "waiting":
		return mk.wait, stWarn, "waiting"
	case s.Status == "starting":
		return mk.idle, stDim, "starting"
	default:
		return mk.head, stHead, "running"
	}
}

func agentModel(r *Run) string {
	if r.State == nil {
		return ""
	}
	return strings.TrimSpace(r.State.Agent + " " + r.State.Model)
}

func planCell(r *Run) string {
	if r.State == nil || r.State.TodoCounts.Total == 0 {
		return "-"
	}
	return fmt.Sprintf("%d/%d", r.State.TodoCounts.Done, r.State.TodoCounts.Total)
}

func quietPrefix(r *Run, now time.Time, mk marks) string {
	if !r.Open() || r.ModTime.IsZero() {
		return ""
	}
	d := now.Sub(r.ModTime)
	if d < quietAfter {
		return ""
	}
	return "quiet " + Duration(int64(d/time.Second)) + " " + mk.sep + " "
}

// -------------------------------------------------------------------- run --

func (m *model) current() *Run {
	for _, r := range m.runs {
		if r.Dir == m.dir {
			return r
		}
	}
	return nil
}

func (m *model) openRun(dir string) {
	m.mode = runMode
	m.dir = dir
	m.raw, m.styled, m.wrapped = nil, nil, nil
	m.offset, m.partial, m.tailErr = 0, "", nil
	m.layout()
	m.rend = NewRenderer(m.ascii, m.wrapWidth())
	m.rend.Markdown = m.markdown
	m.vp.SetContent("")
	m.vp.GotoTop()
	m.pull(true)
	m.vp.GotoBottom()
}

func (m *model) runKey(k tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch k.String() {
	case "q":
		return m, tea.Quit
	case "esc", "backspace", "h", "left":
		m.mode = fleetMode
		m.sel = m.dir
		return m, nil
	case "p":
		m.showPlan = !m.showPlan
		m.layout()
		return m, nil
	case "m":
		m.markdown = !m.markdown
		m.rerender()
		m.setContent(false)
		return m, nil
	case "G", "end":
		m.vp.GotoBottom()
		return m, nil
	case "g", "home":
		m.vp.GotoTop()
		return m, nil
	}
	var cmd tea.Cmd
	m.vp, cmd = m.vp.Update(k)
	return m, cmd
}

// pull reads what was appended to display.txt and renders it. force sets
// the viewport content even when nothing new arrived.
func (m *model) pull(force bool) {
	lines, off, part, reset, err := Tail(m.dir, m.offset, m.partial)
	m.tailErr = err
	if reset {
		// The file shrank and was read again from the start.
		m.raw, m.styled, m.wrapped = nil, nil, nil
		m.rend = NewRenderer(m.ascii, m.wrapWidth())
		m.rend.Markdown = m.markdown
		force = true
	}
	unchanged := !force && len(lines) == 0 && part == m.partial
	m.offset, m.partial = off, part
	var fresh []string
	for _, l := range lines {
		m.raw = append(m.raw, l)
		fresh = append(fresh, m.rend.Line(l)...)
	}
	if r := m.current(); r != nil && !r.Open() && m.partial == "" {
		fresh = append(fresh, m.rend.Flush()...)
	}
	m.styled = append(m.styled, fresh...)
	for _, l := range fresh {
		m.wrapped = append(m.wrapped, m.wrap(l)...)
	}
	m.setContent(unchanged && len(fresh) == 0)
}

// rerender renders every line read so far again: after the markdown toggle
// or a width change while markdown is on (Glamour wraps to the width).
func (m *model) rerender() {
	m.rend = NewRenderer(m.ascii, m.wrapWidth())
	m.rend.Markdown = m.markdown
	m.styled = nil
	for _, l := range m.raw {
		m.styled = append(m.styled, m.rend.Line(l)...)
	}
	if r := m.current(); r != nil && !r.Open() {
		m.styled = append(m.styled, m.rend.Flush()...)
	}
	m.rewrapAll()
}

func (m *model) rewrapAll() {
	m.wrapped = m.wrapped[:0]
	for _, l := range m.styled {
		m.wrapped = append(m.wrapped, m.wrap(l)...)
	}
}

func (m *model) wrapWidth() int {
	w := m.vp.Width
	if w < 20 {
		w = 20
	}
	return w
}

func (m *model) wrap(line string) []string {
	if ansi.StringWidth(line) <= m.wrapWidth() {
		return []string{line}
	}
	return strings.Split(ansi.Wrap(line, m.wrapWidth(), ""), "\n")
}

// setContent hands the wrapped lines to the viewport. The view follows the
// tail while it is at the bottom and stays put once the reader scrolls up.
func (m *model) setContent(unchanged bool) {
	if unchanged {
		return
	}
	follow := m.vp.AtBottom()
	lines := m.wrapped[:len(m.wrapped):len(m.wrapped)]
	for _, l := range m.rend.Pending() {
		lines = append(lines, m.wrap(l)...)
	}
	if m.partial != "" {
		lines = append(lines, m.wrap(m.rend.Preview(m.partial))...)
	}
	if len(lines) == 0 {
		msg := "nothing in display.txt yet"
		if m.tailErr != nil {
			msg = "waiting for display.txt"
		}
		lines = []string{stDim.Render(msg)}
	}
	m.vp.SetContent(strings.Join(lines, "\n"))
	if follow {
		m.vp.GotoBottom()
	}
}

// layout sizes the viewport to what the header, plan panel, and footer
// leave over.
func (m *model) layout() {
	r := m.current()
	used := len(m.headerLines(r)) + 1 + 1 + len(m.footerLines(r))
	if p := m.planLines(r); len(p) > 0 {
		used += len(p) + 1
	}
	h := m.height - used
	if h < 1 {
		h = 1
	}
	m.vp.Width = m.width
	m.vp.Height = h
}

func (m *model) runView() string {
	r := m.current()
	parts := m.headerLines(r)
	parts = append(parts, m.rule())
	if p := m.planLines(r); len(p) > 0 {
		parts = append(parts, p...)
		parts = append(parts, m.rule())
	}
	parts = append(parts, m.vp.View(), m.rule())
	parts = append(parts, m.footerLines(r)...)
	return strings.Join(parts, "\n")
}

func (m *model) headerLines(r *Run) []string {
	if r == nil || r.State == nil {
		return []string{fit(stBold.Render(filepath.Base(m.dir)), m.width),
			fit(stDim.Render("  no state.json yet"), m.width)}
	}
	s := r.State
	mark, st, _ := runMark(r, m.mk)
	left := st.Render(mark) + " " + stBold.Render(r.Label(m.mk.sep))
	var right []string
	if am := agentModel(r); am != "" {
		right = append(right, am)
	}
	right = append(right, Duration(int64(r.Elapsed(m.now())/time.Second)))
	rightS := stDim.Render(strings.Join(right, " "+m.mk.sep+" "))
	first := left
	if gap := m.width - lipgloss.Width(left) - lipgloss.Width(rightS); gap >= 2 {
		first = left + strings.Repeat(" ", gap) + rightS
	}
	lines := []string{fit(first, m.width)}
	if s.Task != "" {
		lines = append(lines, fit("  "+stDim.Render("task")+"  "+Shorten(s.Task, m.width-8, m.mk), m.width))
	}
	var facts []string
	if s.TodoCounts.Total > 0 {
		facts = append(facts, fmt.Sprintf("plan %d/%d done", s.TodoCounts.Done, s.TodoCounts.Total))
	}
	t := Count(s.Counts.Tools, "tool")
	if s.Counts.ToolErrors > 0 || s.Counts.Errors > 0 {
		e := s.Counts.Errors
		if e < s.Counts.ToolErrors {
			e = s.Counts.ToolErrors
		}
		t += ", " + Count(e, "error")
	}
	facts = append(facts, t)
	if s.Counts.Turns != nil {
		facts = append(facts, Count(*s.Counts.Turns, "turn"))
	}
	if s.Counts.Tokens != nil {
		facts = append(facts, Tokens(*s.Counts.Tokens))
	}
	lines = append(lines, fit("  "+stDim.Render(strings.Join(facts, " "+m.mk.sep+" ")), m.width))
	return lines
}

// planLines is the plan panel: the run's todos from state.json, windowed so
// the active item stays in view.
func (m *model) planLines(r *Run) []string {
	if !m.showPlan || r == nil || r.State == nil || len(r.State.Todos) == 0 {
		return nil
	}
	todos := r.State.Todos
	max := (m.height - 10) / 4
	if max < 3 {
		max = 3
	}
	start := 0
	if len(todos) > max {
		focus := 0
		for i, t := range todos {
			if t.Status == "active" {
				focus = i
				break
			}
			if t.Status == "pending" && focus == 0 {
				focus = i
			}
		}
		start = clamp(focus-max/2, 0, len(todos)-max)
	}
	end := start + max
	if end > len(todos) {
		end = len(todos)
	}
	var out []string
	for _, t := range todos[start:end] {
		pos := fmt.Sprintf("%d/%d", t.N, len(todos))
		var row string
		switch t.Status {
		case "done":
			row = stOK.Render(m.mk.done) + " " + stDim.Render(pos+" "+t.Text)
		case "active":
			row = stHead.Render(m.mk.head) + " " + stDim.Render(pos) + " " + stBold.Render(t.Text)
		case "dropped":
			row = stDim.Render(m.mk.drop + " " + pos + " " + t.Text)
		default:
			row = stDim.Render(m.mk.idle + " " + pos + " " + t.Text)
		}
		out = append(out, fit("  "+row, m.width))
	}
	if start > 0 || end < len(todos) {
		out = append(out, fit(stDim.Render(fmt.Sprintf("  %s %d more", m.mk.ell, len(todos)-(end-start))), m.width))
	}
	return out
}

func (m *model) footerLines(r *Run) []string {
	var now string
	switch {
	case r == nil:
		now = stDim.Render("record not found: " + tilde(m.dir))
	case r.State == nil:
		now = stDim.Render(r.Now())
	case !r.Open():
		mark, st, word := runMark(r, m.mk)
		bits := []string{word}
		if o := r.State.Outcome; o != nil && o.Exit != nil {
			bits = append(bits, fmt.Sprintf("exit %d", *o.Exit))
		}
		bits = append(bits, Duration(r.State.ElapsedS))
		now = st.Render(mark+" "+strings.Join(bits, " "+m.mk.sep+" ")) + "  " + r.Now()
	default:
		mark, st, _ := runMark(r, m.mk)
		now = st.Render(mark) + " " + stDim.Render(quietPrefix(r, m.now(), m.mk)) + r.Now()
	}
	pos := "following"
	if !m.vp.AtBottom() {
		pos = fmt.Sprintf("%d%% (G follows)", int(m.vp.ScrollPercent()*100))
	}
	md := "m markdown"
	if m.markdown {
		md = "m plain"
	}
	keys := strings.Join([]string{pos, "esc fleet", "p plan", md, "q quit", "record " + tilde(m.dir)}, " "+m.mk.sep+" ")
	return []string{fit(now, m.width), fit(stDim.Render(keys), m.width)}
}

// ---------------------------------------------------------------- helpers --

func (m *model) rule() string {
	w := m.width
	if w < 1 {
		w = 1
	}
	return stDim.Render(strings.Repeat(m.mk.h, w))
}

// fit cuts a styled line to the width so the layout's line count holds.
func fit(s string, width int) string {
	if width <= 0 || ansi.StringWidth(s) <= width {
		return s
	}
	return ansi.Truncate(s, width, "")
}

// cell shortens plain text to w columns and pads it to exactly w.
func cell(s string, w int, mk marks) string {
	s = Shorten(s, w, mk)
	if pad := w - lipgloss.Width(s); pad > 0 {
		s += strings.Repeat(" ", pad)
	}
	return s
}

func cellRight(s string, w int, mk marks) string {
	s = Shorten(s, w, mk)
	if pad := w - lipgloss.Width(s); pad > 0 {
		s = strings.Repeat(" ", pad) + s
	}
	return s
}

func clamp(v, lo, hi int) int {
	if hi < lo {
		return lo
	}
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// Tokens formats a token count: 950 tokens, 12.4k tokens, 1.2M tokens.
func Tokens(n int) string {
	switch {
	case n < 1000:
		return Count(n, "token")
	case n < 1000000:
		return fmt.Sprintf("%.1fk tokens", float64(n)/1000)
	default:
		return fmt.Sprintf("%.1fM tokens", float64(n)/1000000)
	}
}

// tilde shortens a path under the home directory the way the pane does.
func tilde(p string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" || home == "/" {
		return p
	}
	if p == home {
		return "~"
	}
	if strings.HasPrefix(p, home+string(filepath.Separator)) {
		return "~" + p[len(home):]
	}
	return p
}

func tildeList(ps []string) string {
	out := make([]string, len(ps))
	for i, p := range ps {
		out[i] = tilde(p)
	}
	return strings.Join(out, ", ")
}
