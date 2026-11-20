package llm

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func sseServer(t *testing.T, wantPath string, check func(*http.Request, map[string]any), events ...string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != wantPath {
			t.Errorf("path = %s, want %s", r.URL.Path, wantPath)
		}
		var body map[string]any
		data, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(data, &body)
		check(r, body)
		w.Header().Set("Content-Type", "text/event-stream")
		for _, e := range events {
			_, _ = io.WriteString(w, "data: "+e+"\n\n")
		}
	}))
}

func collect(t *testing.T, p Provider) (Response, string) {
	t.Helper()
	var deltas strings.Builder
	resp, err := p.Stream(context.Background(), Request{
		System:   "sys",
		Messages: []Message{{Role: "user", Content: "hi"}},
	}, func(s string) error { deltas.WriteString(s); return nil })
	if err != nil {
		t.Fatal(err)
	}
	return resp, deltas.String()
}

func TestOpenAIStream(t *testing.T) {
	srv := sseServer(t, "/v1/chat/completions", func(r *http.Request, body map[string]any) {
		if got := r.Header.Get("Authorization"); got != "Bearer k" {
			t.Errorf("auth = %q", got)
		}
		msgs := body["messages"].([]any)
		if len(msgs) != 2 || msgs[0].(map[string]any)["role"] != "system" {
			t.Errorf("messages = %v", msgs)
		}
	},
		`{"choices":[{"delta":{"content":"Hel"}}]}`,
		`{"choices":[{"delta":{"content":"lo"}}]}`,
		`[DONE]`,
	)
	defer srv.Close()

	p, err := New(Config{Provider: "custom", BaseURL: srv.URL, APIKey: "k", Model: "m"})
	if err != nil {
		t.Fatal(err)
	}
	resp, deltas := collect(t, p)
	if resp.Text != "Hello" || deltas != "Hello" || resp.Model != "m" {
		t.Fatalf("resp = %+v deltas = %q", resp, deltas)
	}
}

func TestAnthropicStream(t *testing.T) {
	srv := sseServer(t, "/v1/messages", func(r *http.Request, body map[string]any) {
		if r.Header.Get("x-api-key") != "k" || r.Header.Get("anthropic-version") == "" {
			t.Errorf("headers = %v", r.Header)
		}
		if body["system"] != "sys" {
			t.Errorf("system = %v", body["system"])
		}
	},
		`{"type":"message_start"}`,
		`{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}`,
		`{"type":"content_block_delta","delta":{"type":"text_delta","text":" there"}}`,
		`{"type":"message_stop"}`,
	)
	defer srv.Close()

	p, err := New(Config{Provider: "anthropic", BaseURL: srv.URL + "/v1", APIKey: "k"})
	if err != nil {
		t.Fatal(err)
	}
	resp, _ := collect(t, p)
	if resp.Text != "Hi there" {
		t.Fatalf("text = %q", resp.Text)
	}
}

func TestNewValidation(t *testing.T) {
	cases := []Config{
		{Provider: "openai"},              // missing key
		{Provider: "qwen", APIKey: "k"},   // missing model
		{Provider: "custom", APIKey: "k"}, // missing base URL
	}
	for _, cfg := range cases {
		if _, err := New(cfg); !errors.Is(err, ErrNotConfigured) {
			t.Errorf("New(%+v) err = %v, want ErrNotConfigured", cfg, err)
		}
	}
	if _, err := New(Config{Provider: "ollama", Model: "llama3"}); err != nil {
		t.Errorf("ollama without key: %v", err)
	}
	if _, err := New(Config{Provider: "nope"}); err == nil {
		t.Error("unknown provider accepted")
	}
}

func TestNormalizeBaseURL(t *testing.T) {
	cases := map[string]string{
		"https://api.openai.com":                "https://api.openai.com/v1",
		"https://api.openai.com/":               "https://api.openai.com/v1",
		"https://open.bigmodel.cn/api/paas/v4/": "https://open.bigmodel.cn/api/paas/v4",
		"":                                      "",
	}
	for in, want := range cases {
		if got := normalizeBaseURL(in); got != want {
			t.Errorf("normalizeBaseURL(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestConfigFromEnvLegacyFallback(t *testing.T) {
	t.Setenv("CROW_LLM_PROVIDER", "")
	t.Setenv("CROW_LLM_API_KEY", "")
	t.Setenv("CROW_OPENAI_API_KEY", "legacy")
	t.Setenv("CROW_OPENAI_AGENT_MODEL", "gpt-x")
	cfg := ConfigFromEnv()
	if cfg.Provider != "openai" || cfg.APIKey != "legacy" || cfg.Model != "gpt-x" {
		t.Fatalf("cfg = %+v", cfg)
	}
}
