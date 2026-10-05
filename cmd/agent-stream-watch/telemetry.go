package main

// Forge telemetry in the run view: the stage, a forecast, a heartbeat, the
// metrics as sparklines, and the stage timeline, all from state.json
// ([metric] and [stage] lines, docs/spec-themes.md section 6).

import (
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"
)

// metricOrder is the project's preferred metrics (.agent-stream/config.json
// "metrics"); main sets it.
var metricOrder []string

const maxMetrics = 4

// Sparkline draws values as one row of block heights, scaled between their
// own minimum and maximum, the newest on the right.
func Sparkline(values []float64, width int, ascii bool) string {
	levels := []rune("▁▂▃▄▅▆▇█")
	if ascii {
		levels = []rune("_.-=+*#@")
	}
	if width <= 0 || len(values) == 0 {
		return ""
	}
	if len(values) > width {
		values = values[len(values)-width:]
	}
	lo, hi := values[0], values[0]
	for _, v := range values {
		lo, hi = math.Min(lo, v), math.Max(hi, v)
	}
	var b strings.Builder
	for _, v := range values {
		i := len(levels) / 2
		if hi > lo {
			i = int((v - lo) / (hi - lo) * float64(len(levels)-1))
		}
		b.WriteRune(levels[i])
	}
	return b.String()
}

// ETA is the forecast for an open run: the elapsed time per finished unit
// (stage or plan item) times the units left, once two units have finished.
func ETA(r *Run, now time.Time) (time.Duration, bool) {
	if r == nil || r.State == nil || !r.Open() || r.State.Progress == nil {
		return 0, false
	}
	p := r.State.Progress
	if p.Done < 2 || p.Done >= p.Total {
		return 0, false
	}
	el := r.Elapsed(now)
	return time.Duration(float64(el) * float64(p.Total-p.Done) / float64(p.Done)).Truncate(time.Second), true
}

// metricNames is the order metrics are shown: the project's list first,
// then the rest by name, at most four.
func metricNames(ms map[string]Metric) []string {
	var out []string
	seen := map[string]bool{}
	for _, n := range metricOrder {
		if _, ok := ms[n]; ok && !seen[n] {
			out, seen[n] = append(out, n), true
		}
	}
	var rest []string
	for n := range ms {
		if !seen[n] {
			rest = append(rest, n)
		}
	}
	sort.Strings(rest)
	out = append(out, rest...)
	if len(out) > maxMetrics {
		out = out[:maxMetrics]
	}
	return out
}

// formatValue keeps a metric short: 0.0031, 1500, 1.5e+06.
func formatValue(v float64) string {
	s := strconv.FormatFloat(v, 'g', 4, 64)
	return s
}

// telemetryLines is the panel under the run header, or nothing when the run
// reports no stages and no metrics.
func (m *model) telemetryLines(r *Run) []string {
	if r == nil || r.State == nil || (len(r.State.Metrics) == 0 && r.State.Stage == nil) {
		return nil
	}
	s := r.State
	now := m.now()
	var head []string
	if s.Stage != nil {
		head = append(head, stHead.Render(m.mk.active)+" "+stBold.Render(strings.TrimSpace(fmt.Sprintf("%s %d/%d %s", cur.Words.Stage, s.Stage.I, s.Stage.N, s.Stage.Name))))
	}
	if eta, ok := ETA(r, now); ok {
		head = append(head, stHead.Render(cur.Words.ETA+" "+Duration(int64(eta/time.Second)))+stDim.Render(" (forecast)"))
	}
	if r.Open() && !r.ModTime.IsZero() {
		age := now.Sub(r.ModTime)
		beat := stOK
		if age >= quietAfter {
			beat = stWarn
		}
		head = append(head, beat.Render("♥")+stDim.Render(" "+cur.Words.Heartbeat+" "+Duration(int64(age/time.Second))+" ago"))
		if m.ascii {
			head[len(head)-1] = beat.Render("*") + stDim.Render(" "+cur.Words.Heartbeat+" "+Duration(int64(age/time.Second))+" ago")
		}
	}
	var lines []string
	if len(head) > 0 {
		lines = append(lines, fit("  "+strings.Join(head, stDim.Render(" "+m.mk.sep+" ")), m.width))
	}
	names := metricNames(s.Metrics)
	w := 0
	for _, n := range names {
		if len(n) > w {
			w = len(n)
		}
	}
	spark := clamp(m.width-w-30, 8, 40)
	for _, n := range names {
		mt := s.Metrics[n]
		vals := make([]float64, len(mt.History))
		for i, h := range mt.History {
			vals[i] = h[1]
		}
		line := fmt.Sprintf("  %s %s  %s",
			stDim.Render(fmt.Sprintf("%-*s", w, n)),
			stOK.Render(fmt.Sprintf("%-*s", spark, Sparkline(vals, spark, m.ascii))),
			stBold.Render(formatValue(mt.Value)))
		if mt.Unit != "" {
			line += " " + stDim.Render(mt.Unit)
		}
		lines = append(lines, fit(line, m.width))
	}
	if len(s.Stages) > 1 {
		var parts []string
		elapsed := float64(r.Elapsed(now) / time.Second)
		for _, st := range s.Stages {
			d := ""
			if st.StartedS != nil {
				end := elapsed
				if st.EndedS != nil {
					end = *st.EndedS
				}
				d = " " + Duration(int64(end-*st.StartedS))
			}
			mark := m.mk.lit
			if st.EndedS == nil && r.Open() {
				mark = m.mk.active
			}
			parts = append(parts, fmt.Sprintf("%s %d %s%s", mark, st.I, st.Name, d))
		}
		lines = append(lines, fit("  "+stDim.Render(strings.Join(parts, " "+m.mk.sep+" ")), m.width))
	}
	return lines
}
