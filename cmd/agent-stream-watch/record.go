package main

// Record access: a run is a directory holding state.json (written by
// lib/agent-state.sh) and display.txt (the activity line protocol). The
// watcher only reads these files; it never writes to a record.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// State mirrors docs/design.md section 6. Fields the watcher does not show
// are left out; unknown fields are ignored by encoding/json.
type State struct {
	Schema         string  `json:"schema"`
	ID             string  `json:"id"`
	Status         string  `json:"status"`
	Agent          string  `json:"agent"`
	Model          string  `json:"model"`
	ModelRequested string  `json:"model_requested"`
	Session        string  `json:"session"`
	Project        Project `json:"project"`
	Task           string  `json:"task"`
	StartedAt      string  `json:"started_at"`
	UpdatedAt      string  `json:"updated_at"`
	EndedAt        string  `json:"ended_at"`
	ElapsedS       int64   `json:"elapsed_s"`
	Activity       struct {
		Kind string `json:"kind"`
		Text string `json:"text"`
	} `json:"activity"`
	Step    string `json:"step"`
	Waiting *struct {
		Kind string `json:"kind"`
		Text string `json:"text"`
	} `json:"waiting"`
	Todos []struct {
		N      int    `json:"n"`
		Text   string `json:"text"`
		Status string `json:"status"`
	} `json:"todos"`
	TodoCounts struct {
		Total   int `json:"total"`
		Done    int `json:"done"`
		Active  int `json:"active"`
		Pending int `json:"pending"`
		Dropped int `json:"dropped"`
	} `json:"todo_counts"`
	Counts struct {
		Tools      int  `json:"tools"`
		ToolErrors int  `json:"tool_errors"`
		Errors     int  `json:"errors"`
		Warnings   int  `json:"warnings"`
		Waits      int  `json:"waits"`
		Turns      *int `json:"turns"`
		Tokens     *int `json:"tokens"`
	} `json:"counts"`
	LastText  string `json:"last_text"`
	LastError string `json:"last_error"`
	Outcome   *struct {
		Kind    string `json:"kind"`
		Exit    *int   `json:"exit"`
		Summary string `json:"summary"`
		Detail  string `json:"detail"`
	} `json:"outcome"`
	Record struct {
		Dir     string `json:"dir"`
		Display string `json:"display"`
	} `json:"record"`
	Metrics  map[string]Metric `json:"metrics"`
	Stages   []Stage           `json:"stages"`
	Stage    *Stage            `json:"stage"`
	Progress *struct {
		Done   int    `json:"done"`
		Total  int    `json:"total"`
		Source string `json:"source"`
	} `json:"progress"`
	EtaS *int64 `json:"eta_s"`
}

// Metric is one [metric] series: the latest value, its unit, how many
// samples arrived, and the last 60 as [seconds since start, value].
type Metric struct {
	Value   float64      `json:"value"`
	Unit    string       `json:"unit"`
	N       int          `json:"n"`
	History [][2]float64 `json:"history"`
}

// Stage is one [stage] of a multi-stage job.
type Stage struct {
	I        int      `json:"i"`
	N        int      `json:"n"`
	Name     string   `json:"name"`
	StartedS *float64 `json:"started_s"`
	EndedS   *float64 `json:"ended_s"`
}

// Project is the where of a run.
type Project struct {
	Name   string `json:"name"`
	Dir    string `json:"dir"`
	Branch string `json:"branch"`
}

// Run is one record directory and what the watcher knows about it.
type Run struct {
	Dir      string
	State    *State
	StateErr error
	ModTime  time.Time // state.json mtime, or the directory's when absent
	Loaded   time.Time
}

// Elapsed is the run's age: the recorded elapsed seconds once ended, the
// time since started_at while open, zero when nothing is known.
func (r *Run) Elapsed(now time.Time) time.Duration {
	if r.State == nil {
		return 0
	}
	if r.State.Status == "ended" {
		return time.Duration(r.State.ElapsedS) * time.Second
	}
	if t, err := time.Parse(time.RFC3339, r.State.StartedAt); err == nil {
		d := now.Sub(t)
		if d < 0 {
			d = 0
		}
		return d.Truncate(time.Second)
	}
	return time.Duration(r.State.ElapsedS) * time.Second
}

// Open reports whether the run has not ended.
func (r *Run) Open() bool {
	return r.State != nil && r.State.Status != "ended"
}

// Label is the run's project and branch joined by sep, falling back to the
// directory name.
func (r *Run) Label(sep string) string {
	if r.State != nil && r.State.Project.Name != "" {
		if r.State.Project.Branch != "" {
			return r.State.Project.Name + " " + sep + " " + r.State.Project.Branch
		}
		return r.State.Project.Name
	}
	return filepath.Base(r.Dir)
}

// Now is one line about what the run is doing or waiting for.
func (r *Run) Now() string {
	s := r.State
	if s == nil {
		return "no state yet"
	}
	if s.Status == "ended" {
		if s.Outcome != nil && s.Outcome.Summary != "" {
			return s.Outcome.Summary
		}
		if k := r.OutcomeKind(); (k == "failed" || k == "error") && s.LastError != "" {
			return s.LastError
		}
		if s.LastText != "" {
			return s.LastText
		}
		return "ended"
	}
	if s.Waiting != nil {
		w := cur.Words.Wait
		if s.Waiting.Kind != "" {
			w += " (" + s.Waiting.Kind + ")"
		}
		if s.Waiting.Text != "" {
			w += " " + s.Waiting.Text
		}
		return w
	}
	if s.Step != "" {
		return s.Step
	}
	if s.Stage != nil {
		return strings.TrimSpace(fmt.Sprintf("%s %d/%d %s", cur.Words.Stage, s.Stage.I, s.Stage.N, s.Stage.Name))
	}
	if s.Activity.Kind == "tool" && s.Activity.Text != "" {
		// A tool is open right now: more specific than the plan item,
		// which the plan column and panel already show.
		return "running " + s.Activity.Text
	}
	for _, t := range s.Todos {
		if t.Status == "active" {
			return t.Text
		}
	}
	switch s.Activity.Kind {
	case "tool":
		return "running " + s.Activity.Text
	case "think":
		return "thinking"
	case "text":
		return s.Activity.Text
	case "done":
		return "finished " + s.Activity.Text
	case "":
		return "starting"
	}
	return s.Activity.Text
}

// OutcomeKind is success, failed, error, cancelled, exited, or "" while open.
func (r *Run) OutcomeKind() string {
	if r.State == nil || r.State.Outcome == nil {
		return ""
	}
	return r.State.Outcome.Kind
}

// LoadState reads and parses one state.json. A missing file is not an
// error for the caller: the run simply has no state yet.
func LoadState(dir string) (*State, time.Time, error) {
	path := filepath.Join(dir, "state.json")
	fi, err := os.Lstat(path)
	if err != nil {
		if di, derr := os.Stat(dir); derr == nil {
			return nil, di.ModTime(), nil
		}
		return nil, time.Time{}, err
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return nil, fi.ModTime(), errors.New("state.json is a symlink")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fi.ModTime(), err
	}
	var s State
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fi.ModTime(), err
	}
	return &s, fi.ModTime(), nil
}

// ScanRoots lists run directories under each root: every directory that
// holds a state.json, a display.txt, or an events.jsonl. A root that is
// itself a record counts as one run.
func ScanRoots(roots []string) []string {
	seen := map[string]bool{}
	var dirs []string
	add := func(d string) {
		if abs, err := filepath.Abs(d); err == nil {
			d = abs
		}
		if !seen[d] {
			seen[d] = true
			dirs = append(dirs, d)
		}
	}
	for _, root := range roots {
		if isRecord(root) {
			add(root)
			continue
		}
		entries, err := os.ReadDir(root)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			d := filepath.Join(root, e.Name())
			if isRecord(d) {
				add(d)
			}
		}
	}
	return dirs
}

func isRecord(dir string) bool {
	for _, f := range []string{"state.json", "display.txt", "events.jsonl"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err == nil {
			return true
		}
	}
	return false
}

// Refresh reloads every run whose state.json changed, adds new runs, and
// drops runs whose directory is gone. It returns the runs sorted: open
// first, then by most recent update.
func Refresh(prev []*Run, roots []string, now time.Time) []*Run {
	byDir := map[string]*Run{}
	for _, r := range prev {
		byDir[r.Dir] = r
	}
	var runs []*Run
	for _, d := range ScanRoots(roots) {
		r, ok := byDir[d]
		if !ok {
			r = &Run{Dir: d}
		}
		mt := stateModTime(d)
		if !ok || mt.IsZero() || mt.After(r.ModTime) || r.State == nil {
			s, m, err := LoadState(d)
			r.State, r.ModTime, r.StateErr, r.Loaded = s, m, err, now
		}
		runs = append(runs, r)
	}
	sort.SliceStable(runs, func(i, j int) bool {
		oi, oj := runs[i].Open(), runs[j].Open()
		if oi != oj {
			return oi
		}
		return runs[i].ModTime.After(runs[j].ModTime)
	})
	return runs
}

func stateModTime(dir string) time.Time {
	fi, err := os.Stat(filepath.Join(dir, "state.json"))
	if err != nil {
		return time.Time{}
	}
	return fi.ModTime()
}

// Tail reads display.txt from offset and returns the complete new lines,
// the new offset, and the unfinished remainder. A file that shrank is read
// again from the start and reset is true, so the caller drops what it had.
func Tail(dir string, offset int64, partial string) (lines []string, newOffset int64, newPartial string, reset bool, err error) {
	f, err := os.Open(filepath.Join(dir, "display.txt"))
	if err != nil {
		return nil, offset, partial, false, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, offset, partial, false, err
	}
	if fi.Size() < offset {
		offset, partial, reset = 0, "", true
	}
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return nil, offset, partial, reset, err
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return nil, offset, partial, reset, err
	}
	buf := partial + string(data)
	parts := strings.Split(buf, "\n")
	newPartial = parts[len(parts)-1]
	lines = parts[:len(parts)-1]
	return lines, offset + int64(len(data)), newPartial, reset, nil
}
