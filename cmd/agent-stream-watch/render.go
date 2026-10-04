package main

// Rendering of the activity line protocol (docs/design.md section 5) with
// the same marks and semantics as lib/agent-present.sh: tool cards, plan
// rows, waits that carry the word, run and end lines. Colors come from the
// terminal's 16-color palette so they match the Bash pane: cyan headings
// and active items, green success, amber attention, red errors, faint
// metadata. Lip Gloss honours NO_COLOR and non-terminals by itself.

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/lipgloss"
)

// The package styles. Use (theme.go) points them at the theme in use; these
// initial values are the base look.
var (
	stHead  = lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
	stOK    = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	stWarn  = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	stErr   = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	stDim   = lipgloss.NewStyle().Faint(true)
	stBold  = lipgloss.NewStyle().Bold(true)
	stThink = lipgloss.NewStyle().Faint(true)
	stSky   = lipgloss.NewStyle().Faint(true)
	stEgg   = lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
)

// GlamourStyle is the Glamour standard style for markdown rendering. main
// picks it once before the event loop starts ("dark", "light", or "notty"),
// because asking the terminal for its background while Bubble Tea owns the
// input would race with key reads.
var GlamourStyle = "dark"

// Marks: unicode by default; ASCII when the terminal says so. The first
// fifteen are the pane's marks; the rest are theme glyphs, which the base
// fills from the pane's marks or leaves empty (an empty glyph switches the
// drawing that needs it off).
type marks struct {
	head, step, done, err, warn, idle, wait, drop, sep, tl, bl, h, v, h2, ell string

	active, unknown, pending, lit           string // plan rows and the selected row
	cardOpen, cardClose                     string // header and report cards
	launch, trail, ahead, sky, orbit, field string // trajectory, background, spinner
}

var uni = marks{"▸", "·", "✓", "✗", "!", "·", "~", "–", "·", "┌", "└", "─", "│", "──", "…",
	"▸", "?", "·", "✓", "", "", "", "", "", "", "", ""}
var asc = marks{">", "-", "+", "x", "!", ".", "~", "-", "-", "+", "+", "-", "|", "--", "...",
	">", "?", ".", "+", "", "", "", "", "", "", "", ""}

// word puts a theme word in front of a text, or returns the text alone.
func word(w, text string) string {
	if w == "" {
		return text
	}
	if text == "" {
		return w
	}
	return w + " " + text
}

var labelRe = regexp.MustCompile(`^\[(run|tool|done|error|warn|note|think|wait|todo|step|end)\](?: (.*)|)$`)
var todoRe = regexp.MustCompile(`^(\d+)/(\d+) (pending|active|done|dropped)(?: (.*))?$`)
var ctrlRe = regexp.MustCompile("[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

// clean strips control bytes that should never be in display.txt anyway.
func clean(s string) string {
	s = strings.ReplaceAll(s, "\r", "")
	return ctrlRe.ReplaceAllString(s, "")
}

// Renderer turns protocol lines into styled terminal lines, keeping the
// small amount of state the Bash presenter keeps: open cards, whether the
// previous row was a plan row, whether a think span is open, and whether
// anything has been printed yet (for the air before cards).
type Renderer struct {
	m          marks
	openCards  int
	prevTodo   bool
	thinking   bool
	started    bool
	Markdown   bool
	width      int
	prose      []string // pending plain lines when Markdown is on
	pendingN   int      // len(prose) when pendingOut was rendered
	pendingOut []string
	md         *glamour.TermRenderer
	mdWidth    int
}

// NewRenderer picks marks for the terminal and sets the wrap width used
// by markdown rendering.
func NewRenderer(ascii bool, width int) *Renderer {
	return &Renderer{m: cur.Marks(ascii), width: width}
}

// SetWidth changes the markdown wrap width; the renderer is rebuilt lazily.
func (r *Renderer) SetWidth(w int) { r.width = w }

// Line renders one protocol line into zero or more output lines.
func (r *Renderer) Line(raw string) []string {
	line := clean(raw)
	m := labelRe.FindStringSubmatch(line)
	if m == nil {
		return r.plain(line)
	}
	out := r.flushProse()
	label, rest := m[1], m[2]
	if label != "todo" {
		r.prevTodo = false
	}
	r.thinking = label == "think"
	switch label {
	case "tool":
		out = append(out, r.air()...)
		name, args := splitFirst(rest)
		body := r.m.step + " " + stDim.Render(word(cur.Words.Tool, name))
		if args != "" {
			body += " " + args
		}
		out = append(out, stDim.Render(r.m.tl+r.m.h)+" "+body)
		r.openCards++
	case "done":
		done := rest
		if cur.Words.Done != "" {
			done = strings.TrimSpace(rest + " " + cur.Words.Done)
		}
		out = append(out, r.closer(stOK.Render(r.m.done)+" "+stDim.Render(done)))
	case "error":
		out = append(out, r.closer(stErr.Render(r.m.err+" "+word(cur.Words.Error, rest))))
	case "warn":
		out = append(out, r.side(stWarn.Render(r.m.warn+" "+word(cur.Words.Warn, rest))))
	case "note":
		out = append(out, r.side(stDim.Render(word(cur.Words.Note, rest))))
	case "think":
		out = append(out, r.divider(stThink.Render(r.m.idle+" "+cur.Words.Think+optional(rest)))...)
	case "wait":
		kind, text := splitFirst(rest)
		kind = strings.TrimSuffix(kind, ":")
		body := stWarn.Render(r.m.wait+" "+cur.Words.Wait) + " " + stDim.Render("("+kind+")")
		if text != "" {
			body += " " + text
		}
		out = append(out, r.side(body))
	case "step":
		out = append(out, r.side(stDim.Render(cur.Words.Step)+" "+rest))
	case "run":
		if strings.HasPrefix(rest, "result ") {
			res := strings.TrimPrefix(rest, "result ")
			if isGoodResult(res) {
				out = append(out, r.side(stOK.Render(r.m.done)+" "+stDim.Render(word(cur.Words.ResultOK, "result "+res))))
			} else {
				out = append(out, r.side(stWarn.Render(r.m.warn+" result "+res)))
			}
		} else {
			launch := ""
			if r.m.launch != "" {
				launch = stHead.Render(r.m.launch) + " "
			}
			out = append(out, r.side(launch+stDim.Render(word(cur.Words.Run, rest))))
		}
	case "end":
		kind, _ := splitFirst(rest)
		var body string
		switch kind {
		case "success":
			body = stOK.Render(r.m.done + " " + rest)
		case "failed", "error":
			body = stErr.Render(r.m.err + " " + rest)
		case "cancelled":
			body = stWarn.Render(r.m.warn + " " + rest)
		default:
			body = stDim.Render(r.m.idle + " " + rest)
		}
		out = append(out, r.divider(body)...)
	case "todo":
		out = append(out, r.todoRow(rest)...)
	}
	r.started = true
	return out
}

// Flush returns any prose still pending (markdown mode buffers paragraphs).
func (r *Renderer) Flush() []string { return r.flushProse() }

// Preview styles an unfinished last line (text still streaming, no newline
// yet) without changing the renderer's state, so the reader sees it now and
// the line is rendered properly once it is complete.
func (r *Renderer) Preview(partial string) string {
	line := clean(partial)
	if r.thinking {
		return stThink.Render(line)
	}
	return line
}

func (r *Renderer) plain(line string) []string {
	r.prevTodo = false
	if r.thinking {
		r.started = true
		return []string{stThink.Render(line)}
	}
	if r.Markdown {
		// Prose is held until the next label line so a paragraph run,
		// a list, or a code fence with blank lines renders as one block.
		// Pending shows it in the meantime.
		r.prose = append(r.prose, line)
		return nil
	}
	r.started = true
	return []string{line}
}

func (r *Renderer) flushProse() []string {
	if len(r.prose) == 0 {
		return nil
	}
	text := strings.Join(r.prose, "\n")
	r.prose = nil
	r.pendingN, r.pendingOut = 0, nil
	r.started = true
	return r.markdown(text)
}

// Pending renders the prose held back in markdown mode without consuming
// it, so a live run shows its answer while it streams. The result is
// cached until more prose arrives.
func (r *Renderer) Pending() []string {
	if len(r.prose) == 0 {
		return nil
	}
	if r.pendingN != len(r.prose) || r.pendingOut == nil {
		r.pendingN = len(r.prose)
		r.pendingOut = r.markdown(strings.Join(r.prose, "\n"))
	}
	return r.pendingOut
}

func (r *Renderer) markdown(text string) []string {
	if strings.TrimSpace(text) == "" {
		return []string{""}
	}
	if r.md == nil || r.mdWidth != r.width {
		w := r.width
		if w < 20 {
			w = 20
		}
		md, err := glamour.NewTermRenderer(glamour.WithStandardStyle(GlamourStyle), glamour.WithWordWrap(w), glamour.WithEmoji())
		if err != nil {
			return strings.Split(text, "\n")
		}
		r.md, r.mdWidth = md, r.width
	}
	out, err := r.md.Render(text)
	if err != nil {
		return strings.Split(text, "\n")
	}
	out = strings.Trim(out, "\n")
	return strings.Split(out, "\n")
}

func (r *Renderer) air() []string {
	if r.started {
		return []string{""}
	}
	return nil
}

func (r *Renderer) side(body string) string {
	return stDim.Render(r.m.v) + " " + body
}

func (r *Renderer) closer(body string) string {
	if r.openCards > 0 {
		r.openCards--
		return stDim.Render(r.m.bl+r.m.h) + " " + body
	}
	return r.side(body)
}

func (r *Renderer) divider(body string) []string {
	out := r.air()
	return append(out, stDim.Render(r.m.h2)+" "+body)
}

func (r *Renderer) todoRow(rest string) []string {
	var out []string
	if !r.prevTodo {
		out = append(out, r.divider(stDim.Render(r.m.step+" "+cur.Words.Plan))...)
	}
	r.prevTodo = true
	m := todoRe.FindStringSubmatch(rest)
	if m == nil {
		return append(out, r.side(stWarn.Render(r.m.idle+" "+rest)))
	}
	pos := m[1] + "/" + m[2]
	text := m[4]
	switch m[3] {
	case "done":
		out = append(out, r.side(stOK.Render(r.m.lit)+" "+stDim.Render(pos+" "+text)))
	case "active":
		out = append(out, r.side(stHead.Render(r.m.active)+" "+stDim.Render(pos)+" "+stBold.Render(text)))
	case "dropped":
		out = append(out, r.side(stDim.Render(r.m.drop+" "+pos+" "+text)))
	default:
		out = append(out, r.side(stDim.Render(r.m.pending+" "+pos+" "+text)))
	}
	return out
}

func splitFirst(s string) (string, string) {
	s = strings.TrimSpace(s)
	i := strings.IndexByte(s, ' ')
	if i < 0 {
		return s, ""
	}
	return s[:i], strings.TrimSpace(s[i+1:])
}

func optional(s string) string {
	if s == "" {
		return ""
	}
	return " " + s
}

func isGoodResult(res string) bool {
	for _, p := range []string{"success", "end_turn", "end", "stop"} {
		if strings.HasPrefix(res, p) {
			return true
		}
	}
	return false
}

// Duration formats like the Bash presenter: 42s, 3m12s, 1h02m.
func Duration(secs int64) string {
	if secs < 0 {
		secs = 0
	}
	switch {
	case secs < 60:
		return fmt.Sprintf("%ds", secs)
	case secs < 3600:
		return fmt.Sprintf("%dm%02ds", secs/60, secs%60)
	default:
		return fmt.Sprintf("%dh%02dm", secs/3600, (secs%3600)/60)
	}
}

// Shorten folds a text to one line and cuts it to width with an ellipsis.
func Shorten(s string, width int, m marks) string {
	s = strings.Join(strings.Fields(strings.ReplaceAll(s, "\n", " ")), " ")
	if width < 4 {
		width = 4
	}
	rs := []rune(s)
	if len(rs) <= width {
		return s
	}
	return string(rs[:width-len([]rune(m.ell))]) + m.ell
}

// Count pluralises: 1 tool, 2 tools.
func Count(n int, word string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, word)
	}
	return fmt.Sprintf("%d %ss", n, word)
}
