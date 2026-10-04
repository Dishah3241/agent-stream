package main

// Easter eggs. Each trigger is code; each theme supplies the text (or none)
// under the trigger's id, so the same moment reads as Foundation in the
// space theme and as a radio joke in the radio theme. Eggs fire only on
// real conditions in state.json, never at random, and are off unless the
// theme is loud, the terminal has color, and the project allows them. They
// never replace a state word or an error, and never reach a record.

import (
	"sort"
	"strconv"
	"strings"
	"time"
)

// RunEgg is the egg for a finished run's footer, or "".
func RunEgg(r *Run, now time.Time) string {
	if cur.Eggs == nil || r == nil || r.State == nil || r.Open() {
		return ""
	}
	s := r.State
	kind := r.OutcomeKind()
	total, done := s.TodoCounts.Total, s.TodoCounts.Done
	errs := s.Counts.Errors
	if s.Counts.ToolErrors > errs {
		errs = s.Counts.ToolErrors
	}
	if s.ElapsedS >= 86400 {
		if e := cur.Egg("sol"); e != "" {
			return strings.ReplaceAll(e, "{sol}", strconv.FormatInt(s.ElapsedS/86400+1, 10))
		}
	}
	type cand struct {
		id string
		ok bool
	}
	for _, c := range []cand{
		{"seldon_crisis", (kind == "failed" || kind == "error") && total > 0 && done*2 >= total},
		{"bugs", kind == "success" && errs >= 10},
		{"amaze", kind == "success" && total >= 5 && done == total && errs == 0},
		{"answer_42", s.Counts.Tools == 42},
		{"seldon_approves", kind == "success" && s.ElapsedS >= 3600},
		{"midnight", crossedMidnight(s.StartedAt, s.EndedAt)},
	} {
		if c.ok {
			if e := cur.Egg(c.id); e != "" {
				return e
			}
		}
	}
	return ""
}

// runNowEgg is a short suffix for an open run's "now" text: a run quiet for
// ten minutes, or one waiting on a person for ten minutes.
func runNowEgg(r *Run, now time.Time) string {
	if cur.Eggs == nil || r == nil || r.State == nil || !r.Open() || r.ModTime.IsZero() {
		return ""
	}
	if now.Sub(r.ModTime) < 10*time.Minute {
		return ""
	}
	if r.State.Waiting != nil {
		if e := cur.Egg("litany"); e != "" {
			return " (" + e + ")"
		}
	}
	if e := cur.Egg("dark_forest"); e != "" {
		return " (" + e + ")"
	}
	return ""
}

// FleetEgg is the egg for the fleet title: one long lone run, two runs that
// finished together, or a fleet with nothing running.
func FleetEgg(runs []*Run, now time.Time) string {
	if cur.Eggs == nil || len(runs) == 0 {
		return ""
	}
	var open []*Run
	var landed []time.Time
	for _, r := range runs {
		if r.Open() {
			open = append(open, r)
		} else if r.OutcomeKind() == "success" && r.State != nil {
			if t, err := time.Parse(time.RFC3339, r.State.EndedAt); err == nil {
				landed = append(landed, t)
			}
		}
	}
	if len(open) == 1 && open[0].Elapsed(now) >= 30*time.Minute {
		if e := cur.Egg("wallfacer"); e != "" {
			return e
		}
	}
	sort.Slice(landed, func(i, j int) bool { return landed[i].Before(landed[j]) })
	for i := 1; i < len(landed); i++ {
		if landed[i].Sub(landed[i-1]) <= 10*time.Second && now.Sub(landed[i]) < time.Hour {
			if e := cur.Egg("fist_my_bump"); e != "" {
				return e
			}
		}
	}
	if len(open) == 0 {
		return cur.Egg("dead_channel")
	}
	return ""
}

// crossedMidnight reports whether a run started on one local day and ended
// on another.
func crossedMidnight(start, end string) bool {
	a, err1 := time.Parse(time.RFC3339, start)
	b, err2 := time.Parse(time.RFC3339, end)
	if err1 != nil || err2 != nil {
		return false
	}
	a, b = a.Local(), b.Local()
	return a.YearDay() != b.YearDay() || a.Year() != b.Year()
}
