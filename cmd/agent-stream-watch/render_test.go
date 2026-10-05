package main

import (
	"os"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestMain(m *testing.M) {
	os.Exit(m.Run())
}

// plain is the text a reader sees: Lip Gloss v2 always renders full color
// and leaves downsampling to the output, so tests strip the escapes.
func plain(s string) string { return ansi.Strip(s) }

func renderAll(r *Renderer, lines ...string) string {
	var out []string
	for _, l := range lines {
		out = append(out, r.Line(l)...)
	}
	out = append(out, r.Flush()...)
	return plain(strings.Join(out, "\n"))
}

func TestRenderProtocolLines(t *testing.T) {
	cases := []struct {
		in   []string
		want string
	}{
		{[]string{"[tool] Bash make test", "[done] Bash"}, "┌─ · Bash make test\n└─ ✓ Bash"},
		{[]string{"[tool] Bash make test", "[error] Bash: Error 1"}, "┌─ · Bash make test\n└─ ✗ Bash: Error 1"},
		{[]string{"[error] rpc -32603: boom"}, "│ ✗ rpc -32603: boom"},
		{[]string{"[warn] slow disk"}, "│ ! slow disk"},
		{[]string{"[note] acp agent demo 2.1 (protocol 2)"}, "│ acp agent demo 2.1 (protocol 2)"},
		{[]string{"[wait] permission: Write notes.txt"}, "│ ~ waiting (permission) Write notes.txt"},
		{[]string{"[wait] compacting context"}, "│ ~ waiting (compacting) context"},
		{[]string{"[step] Counting lines"}, "│ now Counting lines"},
		{[]string{"[run] acp demo session sess-dem"}, "│ run acp demo session sess-dem"},
		{[]string{"[run] result end_turn (12400 tokens)"}, "│ ✓ result end_turn (12400 tokens)"},
		{[]string{"[run] result refusal"}, "│ ! result refusal"},
		{[]string{"[todo] 1/2 active Read", "[todo] 2/2 pending Edit"}, "── · plan\n│ ▸ 1/2 Read\n│ · 2/2 Edit"},
		{[]string{"[todo] 1/2 done Read"}, "── · plan\n│ ✓ 1/2 Read"},
		{[]string{"[todo] 2/2 dropped Edit"}, "── · plan\n│ – 2/2 Edit"},
		{[]string{"[think]", "weighing options"}, "── · think\nweighing options"},
		{[]string{"[end] success exit 0 elapsed 3s record /r"}, "── ✓ success exit 0 elapsed 3s record /r"},
		{[]string{"[end] failed exit 1 elapsed 3s record /r"}, "── ✗ failed exit 1 elapsed 3s record /r"},
		{[]string{"plain text"}, "plain text"},
		{[]string{"[stage] 2/7 mesh"}, "── ▸ stage 2/7 mesh"},
		{[]string{"[metric] residual=0.0031"}, "│ metric residual 0.0031"},
		{[]string{"[metric] rate=1.5e3 items/s"}, "│ metric rate 1.5e3 items/s"},
		{[]string{"[metric] bogus"}, "│ [metric] bogus"},
		{[]string{"text with \x1b[2Jcontrol\x07 bytes\r"}, "text with [2Jcontrol bytes"},
	}
	for _, c := range cases {
		got := renderAll(NewRenderer(false, 80), c.in...)
		if got != c.want {
			t.Errorf("%q\n got: %q\nwant: %q", c.in, got, c.want)
		}
	}
}

func TestRenderAirBeforeCardsAndPlans(t *testing.T) {
	got := renderAll(NewRenderer(false, 80), "Starting.", "[tool] Read a", "[done] Read", "[todo] 1/1 active x")
	want := "Starting.\n\n┌─ · Read a\n└─ ✓ Read\n\n── · plan\n│ ▸ 1/1 x"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestRenderASCII(t *testing.T) {
	got := renderAll(NewRenderer(true, 80), "[tool] Bash ls", "[done] Bash", "[todo] 1/1 done x")
	want := "+- - Bash ls\n+- + Bash\n\n-- - plan\n| + 1/1 x"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
	for _, r := range got {
		if r > 127 {
			t.Fatalf("ASCII mode printed %q", r)
		}
	}
}

func TestRenderMarkdownBuffersParagraphs(t *testing.T) {
	r := NewRenderer(false, 60)
	r.Markdown = true
	if out := r.Line("Some **bold** prose"); len(out) != 0 {
		t.Fatalf("an unfinished paragraph is held back, got %q", out)
	}
	out := plain(strings.Join(r.Line("[tool] Read x"), "\n"))
	if !strings.Contains(out, "bold") || strings.Contains(out, "**") {
		t.Errorf("a label line flushes the paragraph through Glamour, got %q", out)
	}
	if !strings.Contains(out, "┌─ · Read x") {
		t.Errorf("the card follows the prose, got %q", out)
	}
}

func TestPreviewKeepsState(t *testing.T) {
	r := NewRenderer(false, 80)
	r.Line("[think]")
	if got := plain(r.Preview("half a tho\x1b[1mught")); got != "half a tho[1mught" {
		t.Errorf("preview is sanitized, got %q", got)
	}
	if got := renderAll(r, "half a thought"); got != "half a thought" {
		t.Errorf("preview leaves the renderer as it was, got %q", got)
	}
}

func TestHelpers(t *testing.T) {
	for in, want := range map[int64]string{0: "0s", 42: "42s", 192: "3m12s", 3720: "1h02m", -5: "0s"} {
		if got := Duration(in); got != want {
			t.Errorf("Duration(%d) = %q want %q", in, got, want)
		}
	}
	if got := Shorten("a  b\nc", 10, uni); got != "a b c" {
		t.Errorf("Shorten folds whitespace: %q", got)
	}
	if got := Shorten("abcdefghij", 5, uni); got != "abcd…" {
		t.Errorf("Shorten cuts with an ellipsis: %q", got)
	}
	if got := Shorten("abcdefghij", 6, asc); got != "abc..." {
		t.Errorf("Shorten keeps an ASCII ellipsis inside the width: %q", got)
	}
	if Count(1, "tool") != "1 tool" || Count(2, "tool") != "2 tools" {
		t.Error("Count pluralises")
	}
	for in, want := range map[int]string{1: "1 token", 950: "950 tokens", 12400: "12.4k tokens", 1250000: "1.2M tokens"} {
		if got := Tokens(in); got != want {
			t.Errorf("Tokens(%d) = %q want %q", in, got, want)
		}
	}
}
