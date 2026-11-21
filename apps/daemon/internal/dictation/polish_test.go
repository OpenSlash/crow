package dictation

import (
	"context"
	"strings"
	"testing"

	"github.com/crow/crow/apps/daemon/internal/llm"
)

type fakeProvider struct {
	reply string
	got   llm.Request
}

func (f *fakeProvider) Stream(_ context.Context, req llm.Request, _ func(string) error) (llm.Response, error) {
	f.got = req
	return llm.Response{Text: f.reply}, nil
}

func TestPolishSendsTranscriptAndVocabulary(t *testing.T) {
	p := &fakeProvider{reply: "  明天下午三点开会。\n"}
	out, err := Polish(context.Background(), p, "嗯明天那个下午两点不对三点开会", "Mail", []string{"Crow", " ", "Crow", "Codex"})
	if err != nil {
		t.Fatal(err)
	}
	if out != "明天下午三点开会。" {
		t.Fatalf("out = %q", out)
	}
	if !strings.Contains(p.got.System, "Vocabulary: Crow, Codex") || !strings.Contains(p.got.System, "typed into Mail") {
		t.Fatalf("system prompt missing context: %s", p.got.System)
	}
	if !strings.Contains(p.got.Messages[0].Content, "<transcript>\n嗯明天") {
		t.Fatalf("transcript not wrapped: %q", p.got.Messages[0].Content)
	}
}

func TestPolishRejectsAnswers(t *testing.T) {
	p := &fakeProvider{reply: strings.Repeat("北京今天晴，气温二十度，适合出门。", 5)}
	if _, err := Polish(context.Background(), p, "今天天气怎么样", "", nil); err == nil {
		t.Fatal("expected an error for output much longer than the transcript")
	}
}

func TestPolishEmpty(t *testing.T) {
	out, err := Polish(context.Background(), &fakeProvider{}, "  ", "", nil)
	if err != nil || out != "" {
		t.Fatalf("out=%q err=%v", out, err)
	}
}

func (*fakeProvider) Name() string  { return "fake" }
func (*fakeProvider) Model() string { return "fake" }
