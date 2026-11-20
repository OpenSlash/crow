package agent

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/crow/crow/apps/daemon/internal/llm"
	"github.com/crow/crow/apps/daemon/internal/memory"
)

// scriptedProvider returns one scripted response per call and records requests.
type scriptedProvider struct {
	responses []llm.Response
	requests  []llm.Request
}

func (p *scriptedProvider) Name() string  { return "fake" }
func (p *scriptedProvider) Model() string { return "fake-1" }
func (p *scriptedProvider) Stream(_ context.Context, req llm.Request, onDelta func(string) error) (llm.Response, error) {
	p.requests = append(p.requests, req)
	resp := p.responses[0]
	if len(p.responses) > 1 {
		p.responses = p.responses[1:]
	}
	if resp.Text != "" {
		if err := onDelta(resp.Text); err != nil {
			return llm.Response{}, err
		}
	}
	return resp, nil
}

type echoTool struct{}

func (echoTool) Spec() llm.Tool {
	return llm.Tool{Name: "echo", Parameters: map[string]any{"type": "object"}}
}
func (echoTool) Activity() Activity { return Activity{Kind: ActivityReading, Label: "Reading"} }
func (echoTool) Run(_ context.Context, args json.RawMessage) (ToolResult, error) {
	return ToolResult{Content: "echo:" + string(args)}, nil
}

func newHandler(p *scriptedProvider, maxSteps int) *Handler {
	return NewHandler(func() (llm.Provider, error) { return p, nil }, maxSteps, echoTool{}, DelegateToCodex())
}

func call(name, args string) llm.Response {
	return llm.Response{ToolCalls: []llm.ToolCall{{ID: "c-" + name, Name: name, Arguments: args}}}
}

func TestRespondStreamSSE(t *testing.T) {
	p := &scriptedProvider{responses: []llm.Response{{Text: "你好", Model: "fake-1", Provider: "fake"}}}
	rec := httptest.NewRecorder()
	newHandler(p, 0).ServeRespondStream(rec, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"input":"hello"}`)))

	body := rec.Body.String()
	for _, want := range []string{
		"event: activity\ndata: {\"kind\":\"thinking\",\"label\":\"Thinking\"}\n\n",
		"event: delta\ndata: {\"text\":\"你好\"}\n\n",
		"event: done\ndata: {\"text\":\"你好\",\"model\":\"fake-1\",\"provider\":\"fake\",\"need_executor\":false}\n\n",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %q in\n%s", want, body)
		}
	}
	if len(p.requests[0].Tools) != 2 {
		t.Errorf("tools not offered: %+v", p.requests[0].Tools)
	}
}

func TestToolLoopFeedsResultsBack(t *testing.T) {
	p := &scriptedProvider{responses: []llm.Response{call("echo", `{"a":1}`), {Text: "done"}}}
	var activities []string
	res, err := newHandler(p, 0).Respond(context.Background(), RespondRequest{Input: "q"}, Events{
		Activity: func(a Activity) error { activities = append(activities, a.Kind); return nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Text != "done" || len(p.requests) != 2 {
		t.Fatalf("res = %+v requests = %d", res, len(p.requests))
	}
	msgs := p.requests[1].Messages
	last := msgs[len(msgs)-1]
	if last.Role != "tool" || last.ToolCallID != "c-echo" || last.Content != `echo:{"a":1}` {
		t.Fatalf("tool result = %+v", last)
	}
	if strings.Join(activities, ",") != "thinking,reading,thinking" {
		t.Fatalf("activities = %v", activities)
	}
}

func TestDelegateToCodexHandsOff(t *testing.T) {
	p := &scriptedProvider{responses: []llm.Response{call("delegate_to_codex", `{"task":"修复 crow 仓库的测试"}`)}}
	var spoken strings.Builder
	res, err := newHandler(p, 0).Respond(context.Background(), RespondRequest{Input: "帮我修一下测试"}, Events{
		Delta: func(s string) error { spoken.WriteString(s); return nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	if !res.NeedExecutor || res.ExecutorHint != "codex" || res.ExecutorTask != "修复 crow 仓库的测试" {
		t.Fatalf("res = %+v", res)
	}
	if spoken.String() != res.Text || res.Text == "" {
		t.Fatalf("handoff text not streamed: %q vs %q", spoken.String(), res.Text)
	}
}

func TestToolErrorsAndUnknownToolsGoBackToModel(t *testing.T) {
	p := &scriptedProvider{responses: []llm.Response{call("delegate_to_codex", `{}`), call("nope", `{}`), {Text: "ok"}}}
	res, err := newHandler(p, 0).Respond(context.Background(), RespondRequest{Input: "q"}, Events{})
	if err != nil || res.Text != "ok" || res.NeedExecutor {
		t.Fatalf("res = %+v err = %v", res, err)
	}
	if got := p.requests[1].Messages[2].Content; !strings.HasPrefix(got, "Error: task is required") {
		t.Fatalf("tool error = %q", got)
	}
	if got := p.requests[2].Messages[4].Content; got != "Error: unknown tool nope" {
		t.Fatalf("unknown tool = %q", got)
	}
}

func TestStepCap(t *testing.T) {
	p := &scriptedProvider{responses: []llm.Response{call("echo", `{}`)}} // loops forever
	res, err := newHandler(p, 3).Respond(context.Background(), RespondRequest{Input: "q"}, Events{})
	if err != nil {
		t.Fatal(err)
	}
	if len(p.requests) != 3 || res.Text == "" {
		t.Fatalf("requests = %d res = %+v", len(p.requests), res)
	}
}

func TestNeedExecutorSkipsModel(t *testing.T) {
	res, err := NewHandler(func() (llm.Provider, error) { panic("provider must not be called") }, 0).
		Respond(context.Background(), RespondRequest{Input: "run tests", NeedExecutor: true}, Events{})
	if err != nil || !res.NeedExecutor || res.ExecutorTask != "run tests" {
		t.Fatalf("res = %+v err = %v", res, err)
	}
}

func TestRespondNotConfigured(t *testing.T) {
	_, cfgErr := llm.New(llm.Config{Provider: "openai"})
	h := NewHandler(func() (llm.Provider, error) { return nil, cfgErr }, 0)
	rec := httptest.NewRecorder()
	h.ServeRespond(rec, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"input":"hi"}`)))
	if rec.Code != http.StatusPreconditionFailed || !strings.Contains(rec.Body.String(), "provider_not_configured") {
		t.Fatalf("code = %d body = %s", rec.Code, rec.Body.String())
	}
}

func TestMemoryToolsAndProfile(t *testing.T) {
	store := memory.Open(t.TempDir())
	if _, err := store.Write("profile", "Name: Alex", false); err != nil {
		t.Fatal(err)
	}
	p := &scriptedProvider{responses: []llm.Response{
		call("memory_write", `{"path":"topics/coffee","content":"Oat latte"}`),
		{Text: "记住了"},
	}}
	enabled := true
	h := newHandler(p, 0).WithMemory(store, func() bool { return enabled })
	if _, err := h.Respond(context.Background(), RespondRequest{Input: "我喜欢燕麦拿铁"}, Events{}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(p.requests[0].System, "<profile>\nName: Alex\n</profile>") || len(p.requests[0].Tools) != 5 {
		t.Fatalf("system = %q tools = %d", p.requests[0].System, len(p.requests[0].Tools))
	}
	if got := p.requests[1].Messages[2].Content; got != "Saved to topics/coffee.md" {
		t.Fatalf("tool result = %q", got)
	}
	if got, _ := store.Read("topics/coffee"); got != "Oat latte\n" {
		t.Fatalf("file = %q", got)
	}

	enabled = false
	p.responses = []llm.Response{{Text: "ok"}}
	if _, err := h.Respond(context.Background(), RespondRequest{Input: "hi"}, Events{}); err != nil {
		t.Fatal(err)
	}
	last := p.requests[len(p.requests)-1]
	if strings.Contains(last.System, "Alex") || len(last.Tools) != 2 {
		t.Fatalf("memory off but system = %q tools = %d", last.System, len(last.Tools))
	}
}

type countingTool struct{ runs *int }

func (countingTool) Spec() llm.Tool {
	return llm.Tool{Name: "count", Parameters: map[string]any{"type": "object"}}
}
func (countingTool) Activity() Activity { return Activity{Kind: ActivityRunning, Label: "Counting"} }
func (t countingTool) Run(context.Context, json.RawMessage) (ToolResult, error) {
	*t.runs++
	return ToolResult{Content: "ok"}, nil
}

func TestCancelSkipsPendingTools(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	runs := 0
	p := &scriptedProvider{responses: []llm.Response{{ToolCalls: []llm.ToolCall{{ID: "a", Name: "count"}, {ID: "b", Name: "count"}}}}}
	h := NewHandler(func() (llm.Provider, error) { return p, nil }, 0, countingTool{&runs})
	_, err := h.Respond(ctx, RespondRequest{Input: "q"}, Events{Activity: func(a Activity) error {
		if a.Kind == ActivityRunning {
			cancel() // user interrupts while the first tool starts
		}
		return nil
	}})
	if !errors.Is(err, context.Canceled) || runs != 1 || len(p.requests) != 1 {
		t.Fatalf("err = %v runs = %d requests = %d", err, runs, len(p.requests))
	}
}

func TestUseComputerOfferedOnlyWhenEnabled(t *testing.T) {
	enabled := false
	p := &scriptedProvider{responses: []llm.Response{{Text: "ok"}}}
	h := NewHandler(func() (llm.Provider, error) { return p, nil }, 0, UseComputer(func() bool { return enabled }))
	_, _ = h.Respond(context.Background(), RespondRequest{Input: "q"}, Events{})
	enabled = true
	_, _ = h.Respond(context.Background(), RespondRequest{Input: "q"}, Events{})
	if len(p.requests[0].Tools) != 0 || len(p.requests[1].Tools) != 1 || p.requests[1].Tools[0].Name != "use_computer" {
		t.Fatalf("tools = %v / %v", p.requests[0].Tools, p.requests[1].Tools)
	}
}

func TestOpenComputerUseSettingsOnlyWhileOff(t *testing.T) {
	off := true
	opened := 0
	tool := OpenComputerUseSettings(func() bool { return off }, func(context.Context) error { opened++; return nil })
	p := &scriptedProvider{responses: []llm.Response{{Text: "ok"}}}
	h := NewHandler(func() (llm.Provider, error) { return p, nil }, 0, tool)
	_, _ = h.Respond(context.Background(), RespondRequest{Input: "q"}, Events{})
	off = false
	_, _ = h.Respond(context.Background(), RespondRequest{Input: "q"}, Events{})
	if len(p.requests[0].Tools) != 1 || len(p.requests[1].Tools) != 0 {
		t.Fatalf("tools = %v / %v", p.requests[0].Tools, p.requests[1].Tools)
	}
	if res, err := tool.Run(context.Background(), nil); err != nil || opened != 1 || !strings.Contains(res.Content, "Save Settings") {
		t.Fatalf("run = %+v %v", res, err)
	}
}

func TestToolPromptNotesFollowAvailability(t *testing.T) {
	on := true
	p := &scriptedProvider{responses: []llm.Response{{Text: "ok"}}}
	h := NewHandler(func() (llm.Provider, error) { return p, nil }, 0,
		UseComputer(func() bool { return on }),
		OpenComputerUseSettings(func() bool { return !on }, func(context.Context) error { return nil }))
	_, _ = h.Respond(context.Background(), RespondRequest{Input: "q"}, Events{})
	on = false
	_, _ = h.Respond(context.Background(), RespondRequest{Input: "q"}, Events{})
	if s := p.requests[0].System; !strings.Contains(s, "Never say you cannot see the screen") || strings.Contains(s, "turned off") {
		t.Fatalf("on prompt = %q", s)
	}
	if s := p.requests[1].System; strings.Contains(s, "Never say you cannot see") || !strings.Contains(s, "Computer use is turned off") {
		t.Fatalf("off prompt = %q", s)
	}
}

func TestDelegateWithoutExecutorTellsModel(t *testing.T) {
	p := &scriptedProvider{responses: []llm.Response{call("delegate_to_codex", `{"task":"fix tests"}`), {Text: "Codex 还没配置"}}}
	h := NewHandler(func() (llm.Provider, error) { return p, nil }, 0, DelegateToCodexIf(func() bool { return false }))
	res, err := h.Respond(context.Background(), RespondRequest{Input: "fix tests"}, Events{})
	if err != nil || res.NeedExecutor || res.Text != "Codex 还没配置" {
		t.Fatalf("res = %+v err = %v", res, err)
	}
	if got := p.requests[1].Messages[2].Content; !strings.Contains(got, "Executors") {
		t.Fatalf("tool result = %q", got)
	}
}
