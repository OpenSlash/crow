package agent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/crow/crow/apps/daemon/internal/llm"
)

type fakeProvider struct{ chunks []string }

func (f fakeProvider) Name() string  { return "fake" }
func (f fakeProvider) Model() string { return "fake-1" }
func (f fakeProvider) Stream(_ context.Context, _ llm.Request, onDelta func(string) error) (llm.Response, error) {
	for _, c := range f.chunks {
		if err := onDelta(c); err != nil {
			return llm.Response{}, err
		}
	}
	return llm.Response{Text: strings.Join(f.chunks, ""), Model: "fake-1", Provider: "fake"}, nil
}

func handler(p llm.Provider, err error) *Handler {
	return NewHandler(func() (llm.Provider, error) { return p, err })
}

func TestRespondStreamSSE(t *testing.T) {
	h := handler(fakeProvider{chunks: []string{"你", "好"}}, nil)
	rec := httptest.NewRecorder()
	h.ServeRespondStream(rec, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"input":"hello"}`)))

	body := rec.Body.String()
	for _, want := range []string{
		"event: delta\ndata: {\"text\":\"你\"}\n\n",
		"event: delta\ndata: {\"text\":\"好\"}\n\n",
		"event: done\ndata: {\"text\":\"你好\",\"model\":\"fake-1\",\"provider\":\"fake\",\"need_executor\":false}\n\n",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %q in\n%s", want, body)
		}
	}
}

func TestRespondDelegatesExecutorInput(t *testing.T) {
	h := handler(nil, nil) // provider must not be called
	res, err := h.Respond(context.Background(), RespondRequest{Input: "帮我修复这个仓库的测试"}, func(string) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if !res.NeedExecutor || res.Provider != "crow-router" {
		t.Fatalf("res = %+v", res)
	}
}

func TestRespondNotConfigured(t *testing.T) {
	_, cfgErr := llm.New(llm.Config{Provider: "openai"})
	h := handler(nil, cfgErr)
	rec := httptest.NewRecorder()
	h.ServeRespond(rec, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"input":"hi"}`)))
	if rec.Code != http.StatusPreconditionFailed || !strings.Contains(rec.Body.String(), "provider_not_configured") {
		t.Fatalf("code = %d body = %s", rec.Code, rec.Body.String())
	}
}
