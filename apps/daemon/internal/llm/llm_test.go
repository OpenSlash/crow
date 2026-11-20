package llm

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

var testTool = Tool{Name: "lookup", Description: "d", Parameters: map[string]any{"type": "object"}}

func toolRequest() Request {
	return Request{
		Messages: []Message{
			{Role: "user", Content: "q"},
			{Role: "assistant", ToolCalls: []ToolCall{{ID: "c0", Name: "lookup", Arguments: `{"x":0}`}}},
			{Role: "tool", ToolCallID: "c0", Content: "r0"},
		},
		Tools: []Tool{testTool},
	}
}

func TestOpenAIToolCalls(t *testing.T) {
	srv := sseServer(t, "/v1/chat/completions", func(r *http.Request, body map[string]any) {
		if tools := body["tools"].([]any); len(tools) != 1 {
			t.Errorf("tools = %v", tools)
		}
		msgs := body["messages"].([]any)
		if msgs[1].(map[string]any)["tool_calls"] == nil || msgs[2].(map[string]any)["tool_call_id"] != "c0" {
			t.Errorf("history not serialized: %v", msgs)
		}
	},
		`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"look","arguments":"{\"x\""}}]}}]}`,
		`{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"up","arguments":":1}"}}]}}]}`,
		`{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c2","function":{"name":"lookup","arguments":""}}]}}]}`,
		`[DONE]`,
	)
	defer srv.Close()
	p, _ := New(Config{Provider: "custom", BaseURL: srv.URL, APIKey: "k", Model: "m"})
	resp, err := p.Stream(context.Background(), toolRequest(), func(string) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	want := []ToolCall{{ID: "c1", Name: "lookup", Arguments: `{"x":1}`}, {ID: "c2", Name: "lookup", Arguments: "{}"}}
	if len(resp.ToolCalls) != 2 || resp.ToolCalls[0] != want[0] || resp.ToolCalls[1] != want[1] {
		t.Fatalf("calls = %+v", resp.ToolCalls)
	}
}

func TestAnthropicToolCalls(t *testing.T) {
	srv := sseServer(t, "/v1/messages", func(r *http.Request, body map[string]any) {
		tools := body["tools"].([]any)
		if tools[0].(map[string]any)["input_schema"] == nil {
			t.Errorf("tools = %v", tools)
		}
		msgs := body["messages"].([]any)
		last := msgs[2].(map[string]any)["content"].([]any)[0].(map[string]any)
		if last["type"] != "tool_result" || last["tool_use_id"] != "c0" {
			t.Errorf("tool result = %v", last)
		}
	},
		`{"type":"content_block_start","index":0,"content_block":{"type":"text"}}`,
		`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}`,
		`{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"lookup"}}`,
		`{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"x\":"}}`,
		`{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"2}"}}`,
		`{"type":"message_stop"}`,
	)
	defer srv.Close()
	p, _ := New(Config{Provider: "anthropic", BaseURL: srv.URL + "/v1", APIKey: "k"})
	resp, err := p.Stream(context.Background(), toolRequest(), func(string) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	if resp.Text != "ok" || len(resp.ToolCalls) != 1 || resp.ToolCalls[0] != (ToolCall{ID: "t1", Name: "lookup", Arguments: `{"x":2}`}) {
		t.Fatalf("resp = %+v", resp)
	}
}

func TestAnthropicMergesToolResults(t *testing.T) {
	msgs := anthropicMessages([]Message{
		{Role: "assistant", ToolCalls: []ToolCall{{ID: "a"}, {ID: "b"}}},
		{Role: "tool", ToolCallID: "a", Content: "1"},
		{Role: "tool", ToolCallID: "b", Content: "2"},
	})
	if len(msgs) != 2 || len(msgs[1]["content"].([]map[string]any)) != 2 {
		t.Fatalf("msgs = %+v", msgs)
	}
}

func TestToolResultImages(t *testing.T) {
	img := Image{MediaType: "image/jpeg", Data: []byte("jpg")}
	msgs := []Message{
		{Role: "user", Content: "look"},
		{Role: "assistant", ToolCalls: []ToolCall{{ID: "a", Name: "computer"}, {ID: "b", Name: "computer"}}},
		{Role: "tool", ToolCallID: "a", Content: "ok", Images: []Image{img}},
		{Role: "tool", ToolCallID: "b", Content: "ok"},
		{Role: "assistant", Content: "done"},
	}

	oa := openAIMessages(Request{Messages: msgs})
	if len(oa) != 6 || oa[2]["role"] != "tool" || oa[3]["role"] != "tool" || oa[4]["role"] != "user" {
		t.Fatalf("openai order = %v", oa)
	}
	parts := oa[4]["content"].([]map[string]any)
	if url := parts[1]["image_url"].(map[string]any)["url"]; url != "data:image/jpeg;base64,anBn" {
		t.Fatalf("image url = %v", url)
	}

	an := anthropicMessages(msgs)
	results := an[2]["content"].([]map[string]any)
	if len(results) != 2 {
		t.Fatalf("anthropic results = %v", results)
	}
	blocks := results[0]["content"].([]map[string]any)
	if blocks[1]["type"] != "image" || blocks[1]["source"].(map[string]any)["data"] != "anBn" {
		t.Fatalf("anthropic image = %v", blocks)
	}
	if results[1]["content"] != "ok" {
		t.Fatalf("plain result = %v", results[1])
	}
}

func TestOpenAILearnsModelQuirks(t *testing.T) {
	var bodies []map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		bodies = append(bodies, body)
		switch {
		case body["max_tokens"] != nil:
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."}}`))
		case body["tools"] != nil && body["reasoning_effort"] == nil:
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"Function tools with reasoning_effort are not supported for m in /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort to 'none'."}}`))
		default:
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"))
		}
	}))
	defer server.Close()
	p, err := New(Config{Provider: "custom", BaseURL: server.URL + "/v1", Model: "quirky-1", APIKey: "k"})
	if err != nil {
		t.Fatal(err)
	}
	req := Request{Messages: []Message{{Role: "user", Content: "hi"}}, MaxTokens: 50, Tools: []Tool{{Name: "noop", Parameters: map[string]any{"type": "object"}}}}
	resp, err := p.Stream(context.Background(), req, func(string) error { return nil })
	if err != nil || resp.Text != "ok" || len(bodies) != 3 {
		t.Fatalf("resp = %+v err = %v attempts = %d", resp, err, len(bodies))
	}
	// Learned once: the next request is right the first time.
	bodies = nil
	if _, err := p.Stream(context.Background(), req, func(string) error { return nil }); err != nil || len(bodies) != 1 {
		t.Fatalf("second request attempts = %d err = %v", len(bodies), err)
	}
	if bodies[0]["max_completion_tokens"] == nil || bodies[0]["reasoning_effort"] != "none" {
		t.Fatalf("body = %v", bodies[0])
	}
}

func TestOpenAISwitchesToResponses(t *testing.T) {
	var paths []string
	var responsesBody map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if strings.HasSuffix(r.URL.Path, "/chat/completions") {
			w.WriteHeader(http.StatusBadRequest)
			if body["reasoning_effort"] == nil {
				_, _ = w.Write([]byte(`{"error":{"message":"Function tools with reasoning_effort are not supported for m in /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort to 'none'."}}`))
			} else {
				_, _ = w.Write([]byte(`{"error":{"message":"Unsupported value: 'reasoning_effort' does not support 'none' with this model."}}`))
			}
			return
		}
		responsesBody = body
		w.Header().Set("Content-Type", "text/event-stream")
		for _, e := range []string{
			`{"type":"response.output_text.delta","delta":"好"}`,
			`{"type":"response.completed","response":{"output":[{"type":"message"},{"type":"function_call","call_id":"call_1","name":"reminder_list","arguments":""}]}}`,
		} {
			_, _ = w.Write([]byte("data: " + e + "\n\n"))
		}
	}))
	defer server.Close()
	p, _ := New(Config{Provider: "custom", BaseURL: server.URL + "/v1", Model: "reasoner-1", APIKey: "k"})
	req := Request{
		System: "sys",
		Messages: []Message{
			{Role: "user", Content: "q"},
			{Role: "assistant", ToolCalls: []ToolCall{{ID: "call_0", Name: "computer", Arguments: `{"action":"screenshot"}`}}},
			{Role: "tool", ToolCallID: "call_0", Content: "ok", Images: []Image{{MediaType: "image/jpeg", Data: []byte("jpg")}}},
		},
		MaxTokens: 100,
		Tools:     []Tool{{Name: "reminder_list", Parameters: map[string]any{"type": "object"}}},
	}
	var streamed string
	resp, err := p.Stream(context.Background(), req, func(s string) error { streamed += s; return nil })
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(paths, ",") != "/v1/chat/completions,/v1/chat/completions,/v1/responses" {
		t.Fatalf("paths = %v", paths)
	}
	if streamed != "好" || len(resp.ToolCalls) != 1 || resp.ToolCalls[0].ID != "call_1" || resp.ToolCalls[0].Arguments != "{}" {
		t.Fatalf("resp = %+v", resp)
	}
	if responsesBody["instructions"] != "sys" || responsesBody["store"] != false || responsesBody["max_output_tokens"].(float64) != 100+reasoningHeadroom {
		t.Fatalf("body = %v", responsesBody)
	}
	input := responsesBody["input"].([]any)
	types := []string{}
	for _, it := range input {
		m := it.(map[string]any)
		types = append(types, fmt.Sprint(m["type"], "/", m["role"]))
	}
	if strings.Join(types, ",") != "<nil>/user,function_call/<nil>,function_call_output/<nil>,<nil>/user" {
		t.Fatalf("input = %v", types)
	}
	// Learned: the next request goes straight to /responses.
	paths = nil
	if _, err := p.Stream(context.Background(), req, func(string) error { return nil }); err != nil || strings.Join(paths, ",") != "/v1/responses" {
		t.Fatalf("second paths = %v err = %v", paths, err)
	}
}
