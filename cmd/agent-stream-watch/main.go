// agent-stream-watch is a lightweight terminal UI onto agent-stream run
// records: a fleet view of every run under the record roots and a run view
// with the context pinned and real scrollback. It reads state.json and
// display.txt only; it never writes to a record and never drives an agent.
// See docs/design.md section 9.1.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
	"golang.org/x/term"
)

const usage = `agent-stream-watch: watch agent-stream run records

  agent-stream-watch [--ascii] [--once] [ROOT_OR_RECORD...]

ROOT is a directory of run records; the default is $AGENT_STREAM_HOME/runs
(AGENT_STREAM_HOME defaults to ~/.agent-stream). A RECORD is one run
directory; given alone it opens straight into the run view. When stdout is
not a terminal, or with --once, the fleet table is printed once and the
command exits.

Fleet keys: j/k or arrows move, enter opens, a toggles all ended runs,
r refreshes now, q quits.
Run keys: arrows, pgup/pgdn, ctrl+u/ctrl+d scroll, g/G top and end (end
follows the tail), p plan panel, m markdown for finished prose, esc back
to the fleet, q quits.

Environment: NO_COLOR, AGENT_RUN_COLOR=never|always, TERM=dumb and a
non-UTF-8 locale (ASCII marks), COLUMNS (width of the printed table).
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("agent-stream-watch", flag.ContinueOnError)
	fs.SetOutput(stderr)
	ascii := fs.Bool("ascii", false, "ASCII marks and borders")
	once := fs.Bool("once", false, "print the fleet table once and exit")
	fs.Usage = func() { fmt.Fprint(stderr, usage) }
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return 0
		}
		return 2
	}
	roots := fs.Args()
	if len(roots) == 0 {
		roots = []string{defaultRoot()}
	}
	for i, r := range roots {
		if abs, err := filepath.Abs(r); err == nil {
			roots[i] = abs
		}
	}
	useASCII := *ascii || wantASCII()
	tty := false
	if f, ok := stdout.(*os.File); ok {
		tty = term.IsTerminal(int(f.Fd()))
	}
	configureColor(tty)

	if *once || !tty {
		now := time.Now()
		runs := Refresh(nil, roots, now)
		fmt.Fprint(stdout, FleetTable(runs, now, useASCII, tableWidth()))
		return 0
	}

	if lipgloss.HasDarkBackground() {
		GlamourStyle = "dark"
	} else {
		GlamourStyle = "light"
	}
	if useASCII {
		GlamourStyle = "notty"
	}
	m := newModel(roots, useASCII, time.Now)
	if len(roots) == 1 && isRecord(roots[0]) {
		m.openRun(roots[0])
	}
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintf(stderr, "agent-stream-watch: %v\n", err)
		return 1
	}
	return 0
}

// FleetTable is the non-interactive fleet: a heading line and one row per
// run, open runs first, then every ended run.
func FleetTable(runs []*Run, now time.Time, ascii bool, width int) string {
	mk := uni
	if ascii {
		mk = asc
	}
	if len(runs) == 0 {
		return "no runs\n"
	}
	var b strings.Builder
	b.WriteString(strings.TrimRight(FleetHead(width, false), " ") + "\n")
	for _, l := range FleetLines(runs, now, mk, width, "", false) {
		b.WriteString(strings.TrimRight(l, " ") + "\n")
	}
	return b.String()
}

func defaultRoot() string {
	home := os.Getenv("AGENT_STREAM_HOME")
	if home == "" {
		h, err := os.UserHomeDir()
		if err != nil {
			h = "."
		}
		home = filepath.Join(h, ".agent-stream")
	}
	return filepath.Join(home, "runs")
}

// wantASCII mirrors lib/agent-present.sh: ASCII for TERM=dumb and for a
// locale that is not UTF-8.
func wantASCII() bool {
	if os.Getenv("TERM") == "dumb" {
		return true
	}
	ctype := os.Getenv("LC_ALL")
	if ctype == "" {
		ctype = os.Getenv("LC_CTYPE")
	}
	if ctype == "" {
		ctype = os.Getenv("LANG")
	}
	c := strings.ToLower(ctype)
	return !strings.Contains(c, "utf-8") && !strings.Contains(c, "utf8")
}

// configureColor mirrors the pane's rules: NO_COLOR and TERM=dumb always
// win, AGENT_RUN_COLOR=never disables color, always forces the 16-color
// palette even when stdout is not a terminal, auto leaves Lip Gloss to
// detect the terminal.
func configureColor(tty bool) {
	switch {
	case os.Getenv("NO_COLOR") != "", os.Getenv("TERM") == "dumb":
		lipgloss.SetColorProfile(termenv.Ascii)
	case os.Getenv("AGENT_RUN_COLOR") == "never":
		lipgloss.SetColorProfile(termenv.Ascii)
	case os.Getenv("AGENT_RUN_COLOR") == "always":
		lipgloss.SetColorProfile(termenv.ANSI)
	case !tty:
		lipgloss.SetColorProfile(termenv.Ascii)
	}
}

func tableWidth() int {
	if n, err := strconv.Atoi(os.Getenv("COLUMNS")); err == nil && n > 0 {
		if n < 60 {
			n = 60
		}
		if n > 200 {
			n = 200
		}
		return n
	}
	return 120
}
