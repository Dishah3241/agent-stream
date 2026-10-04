package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestSparkline(t *testing.T) {
	if got := Sparkline([]float64{1, 2, 3, 4, 5, 6, 7, 8}, 8, false); got != "▁▂▃▄▅▆▇█" {
		t.Errorf("rising values climb, got %q", got)
	}
	if got := Sparkline([]float64{5, 5, 5}, 8, false); got != "▅▅▅" {
		t.Errorf("a flat series sits mid-height, got %q", got)
	}
	if got := Sparkline([]float64{1, 2, 3, 4, 5}, 3, false); got != "▁▄█" {
		t.Errorf("only the newest values fit, got %q", got)
	}
	if got := Sparkline([]float64{0, 1}, 4, true); got != "_@" {
		t.Errorf("ASCII levels, got %q", got)
	}
	if Sparkline(nil, 8, false) != "" {
		t.Error("no values, no line")
	}
}

func telemetryRun(t *testing.T, now time.Time, status string) *Run {
	t.Helper()
	start := now.Add(-40 * time.Minute).UTC().Format(time.RFC3339)
	raw := fmt.Sprintf(`{"status":%q,"started_at":%q,"elapsed_s":2400,
	  "stage":{"i":3,"n":5,"name":"integrate"},
	  "stages":[{"i":1,"n":5,"name":"load","started_s":0,"ended_s":600},
	            {"i":2,"n":5,"name":"mesh","started_s":600,"ended_s":1800},
	            {"i":3,"n":5,"name":"integrate","started_s":1800,"ended_s":null}],
	  "progress":{"done":2,"total":5,"source":"stages"},
	  "metrics":{"residual":{"value":0.0031,"unit":"","n":4,"history":[[0,0.5],[600,0.1],[1200,0.02],[2400,0.0031]]},
	             "rate":{"value":1500,"unit":"items/s","n":1,"history":[[2400,1500]]},
	             "a":{"value":1,"n":1,"history":[[0,1]]},"b":{"value":2,"n":1,"history":[[0,2]]},"c":{"value":3,"n":1,"history":[[0,3]]}}}`,
		status, start)
	var s State
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		t.Fatal(err)
	}
	return &Run{Dir: "/r/forge", State: &s, ModTime: now.Add(-4 * time.Second)}
}

func TestETAAndOrder(t *testing.T) {
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	r := telemetryRun(t, now, "running")
	eta, ok := ETA(r, now)
	if !ok || eta != 60*time.Minute {
		t.Errorf("40 minutes for 2 of 5 stages forecasts 60 more, got %v %v", eta, ok)
	}
	ended := telemetryRun(t, now, "ended")
	if _, ok := ETA(ended, now); ok {
		t.Error("an ended run has no forecast")
	}
	metricOrder = nil
	if got := strings.Join(metricNames(r.State.Metrics), ","); got != "a,b,c,rate" {
		t.Errorf("without a project list, names sort and stop at four: %s", got)
	}
	metricOrder = []string{"residual", "missing", "rate"}
	defer func() { metricOrder = nil }()
	if got := strings.Join(metricNames(r.State.Metrics), ","); got != "residual,rate,a,b" {
		t.Errorf("the project's list comes first: %s", got)
	}
}

func TestTelemetryPanel(t *testing.T) {
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	m := newModel([]string{t.TempDir()}, false, func() time.Time { return now })
	m.width, m.height = 100, 30
	metricOrder = []string{"residual", "rate"}
	defer func() { metricOrder = nil }()
	got := plain(strings.Join(m.telemetryLines(telemetryRun(t, now, "running")), "\n"))
	for _, want := range []string{"▸ stage 3/5 integrate", "ETA 1h00m (forecast)", "♥ last line 4s ago", "residual", "0.0031", "items/s", "✓ 1 load 10m00s", "✓ 2 mesh 20m00s", "▸ 3 integrate 10m00s"} {
		if !strings.Contains(got, want) {
			t.Errorf("panel lacks %q:\n%s", want, got)
		}
	}
	if !strings.Contains(got, "█") || !strings.Contains(got, "▁") {
		t.Errorf("the residual sparkline falls from high to low:\n%s", got)
	}
	for _, l := range strings.Split(got, "\n") {
		if strings.HasSuffix(l, " ") {
			t.Errorf("no trailing spaces: %q", l)
		}
		if len([]rune(l)) > 100 {
			t.Errorf("a panel line is wider than the terminal: %q", l)
		}
	}
	done := plain(strings.Join(m.telemetryLines(telemetryRun(t, now, "ended")), "\n"))
	if !strings.Contains(done, "✓ 3 integrate") || strings.Contains(done, "♥") || strings.Contains(done, "forecast") {
		t.Errorf("an ended run shows every stage finished, no heartbeat, no forecast:\n%s", done)
	}
	if r := telemetryRun(t, now, "running"); r.Now() != "stage 3/5 integrate" {
		t.Errorf("the fleet's now column names the stage, got %q", r.Now())
	}
	if m.telemetryLines(&Run{State: &State{Status: "running"}}) != nil {
		t.Error("no stages and no metrics, no panel")
	}
	useTheme(t, "observatory", false)
	got = plain(strings.Join(m.telemetryLines(telemetryRun(t, now, "running")), "\n"))
	if !strings.Contains(got, "exposure set 3/5 integrate") || !strings.Contains(got, "dawn in 1h00m") || !strings.Contains(got, "last light 4s ago") {
		t.Errorf("observatory words in the panel:\n%s", got)
	}
}
