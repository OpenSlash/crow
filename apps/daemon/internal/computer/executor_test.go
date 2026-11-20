package computer

import (
	"context"
	"strings"
	"sync"
	"testing"

	crowv1 "github.com/crow/crow/apps/daemon/gen/crow/v1"
	"github.com/crow/crow/apps/daemon/internal/executor"
	"github.com/crow/crow/apps/daemon/internal/llm"
)

type scripted struct {
	responses []llm.Response
	requests  []llm.Request
}

func (p *scripted) Name() string  { return "fake" }
func (p *scripted) Model() string { return "fake-1" }
func (p *scripted) Stream(_ context.Context, req llm.Request, _ func(string) error) (llm.Response, error) {
	// Copy messages: the executor mutates its slice when pruning.
	req.Messages = append([]llm.Message(nil), req.Messages...)
	p.requests = append(p.requests, req)
	resp := p.responses[0]
	if len(p.responses) > 1 {
		p.responses = p.responses[1:]
	}
	return resp, nil
}

func call(args string) llm.Response {
	return llm.Response{ToolCalls: []llm.ToolCall{{ID: "c", Name: "computer", Arguments: args}}}
}

type fakeSink struct {
	mu      sync.Mutex
	approve func(executor.ApprovalRequest) bool
	asked   []string
	events  []executor.Event
}

func (s *fakeSink) ApplyExecutorEvent(_ context.Context, _ string, ev executor.Event) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, ev)
	return nil
}

func (s *fakeSink) RequestApproval(_ context.Context, _ string, req executor.ApprovalRequest) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.asked = append(s.asked, req.Scope+":"+req.Action)
	return s.approve == nil || s.approve(req), nil
}

// fakeApp performs no real actions; it records them and returns a tiny screenshot.
func fakeApp(t *testing.T, b *Bridge) (*[]string, func()) {
	ctx, cancel := context.WithCancel(context.Background())
	var actions []string
	var mu sync.Mutex
	commands := b.Watch(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case cmd := <-commands:
				mu.Lock()
				actions = append(actions, cmd.GetAction())
				mu.Unlock()
				_ = b.Submit(&crowv1.ComputerResult{Id: cmd.GetId(), Ok: true, Image: []byte("jpg"), ImageMediaType: "image/jpeg", Width: 1280, Height: 800})
			case <-ctx.Done():
				return
			}
		}
	}()
	return &actions, func() { cancel(); <-done }
}

func run(t *testing.T, p *scripted, sink *fakeSink, seeOnly bool, withApp bool) []string {
	t.Helper()
	b := NewBridge()
	actions := &[]string{}
	if withApp {
		var stop func()
		actions, stop = fakeApp(t, b)
		defer stop()
	}
	e := NewExecutor(b, func() (llm.Provider, error) { return p, nil }, func() bool { return seeOnly }, 10)
	if err := e.Run(context.Background(), executor.Request{TaskID: "t1", Command: "open safari"}, sink); err != nil {
		t.Fatal(err)
	}
	return *actions
}

func TestRunActionsAndScreenshots(t *testing.T) {
	p := &scripted{responses: []llm.Response{
		call(`{"action":"screenshot"}`),
		call(`{"action":"click","x":10,"y":20}`),
		{Text: "Safari is open."},
	}}
	sink := &fakeSink{}
	actions := run(t, p, sink, false, true)
	if strings.Join(actions, ",") != "screenshot,click,release" {
		t.Fatalf("actions = %v", actions)
	}
	last := p.requests[1].Messages[len(p.requests[1].Messages)-1]
	if last.Role != "tool" || len(last.Images) != 1 || !strings.Contains(last.Content, "1280x800") {
		t.Fatalf("screenshot result = %+v", last)
	}
	if strings.Join(sink.asked, ",") != "computer:Use the computer,computer:Clicking" {
		t.Fatalf("approvals = %v", sink.asked)
	}
	if final := sink.events[len(sink.events)-1]; final.Type != "task.completed" || final.Message != "Safari is open." {
		t.Fatalf("final event = %+v", final)
	}
}

func TestSeeOnlyAndDeclined(t *testing.T) {
	p := &scripted{responses: []llm.Response{call(`{"action":"click","x":1,"y":1}`), {Text: "ok"}}}
	actions := run(t, p, &fakeSink{}, true, true)
	if strings.Join(actions, ",") != "release" || !strings.Contains(p.requests[1].Messages[2].Content, "see-only") {
		t.Fatalf("see-only: actions = %v result = %q", actions, p.requests[1].Messages[2].Content)
	}
	if tools := p.requests[0].Tools[0].Parameters["properties"].(map[string]any)["action"].(map[string]any)["enum"].([]string); len(tools) != 5 {
		t.Fatalf("see-only actions offered = %v", tools)
	}

	p = &scripted{responses: []llm.Response{call(`{"action":"type","text":"hi"}`), {Text: "ok"}}}
	sink := &fakeSink{approve: func(r executor.ApprovalRequest) bool { return r.Action == "Use the computer" }}
	actions = run(t, p, sink, false, true)
	if strings.Join(actions, ",") != "release" || !strings.Contains(p.requests[1].Messages[2].Content, "declined") {
		t.Fatalf("declined: actions = %v result = %q", actions, p.requests[1].Messages[2].Content)
	}
}

func TestNotApprovedOrNoApp(t *testing.T) {
	b := NewBridge()
	e := NewExecutor(b, func() (llm.Provider, error) { return &scripted{}, nil }, nil, 10)
	err := e.Run(context.Background(), executor.Request{TaskID: "t1"}, &fakeSink{approve: func(executor.ApprovalRequest) bool { return false }})
	if err == nil || !strings.Contains(err.Error(), "not approved") {
		t.Fatalf("err = %v", err)
	}

	p := &scripted{responses: []llm.Response{call(`{"action":"screenshot"}`), {Text: "no app"}}}
	run(t, p, &fakeSink{}, false, false)
	if got := p.requests[1].Messages[2].Content; !strings.Contains(got, ErrNoApp.Error()) {
		t.Fatalf("no app result = %q", got)
	}
}

func TestPruneScreenshots(t *testing.T) {
	img := []llm.Image{{MediaType: "image/jpeg", Data: []byte("x")}}
	msgs := []llm.Message{{Role: "tool", Images: img}, {Role: "tool", Images: img}, {Role: "tool", Images: img}}
	pruneScreenshots(msgs, 2)
	if msgs[0].Images != nil || msgs[1].Images == nil || msgs[2].Images == nil {
		t.Fatalf("pruned = %+v", msgs)
	}
}

func TestReadOnlyActionsSkipApproval(t *testing.T) {
	p := &scripted{responses: []llm.Response{
		call(`{"action":"zoom","x":0,"y":0,"width":100,"height":50}`),
		call(`{"action":"windows"}`),
		call(`{"action":"focus","name":"Safari"}`),
		{Text: "ok"},
	}}
	sink := &fakeSink{}
	actions := run(t, p, sink, true, true) // see-only: focus must be refused
	if strings.Join(actions, ",") != "zoom,windows,release" {
		t.Fatalf("actions = %v", actions)
	}
	if strings.Join(sink.asked, ",") != "computer:Use the computer" {
		t.Fatalf("approvals = %v", sink.asked)
	}
	if got := p.requests[1].Messages[2].Content; !strings.Contains(got, "Zoomed image") {
		t.Fatalf("zoom result = %q", got)
	}
}

func TestOneTaskAtATime(t *testing.T) {
	b := NewBridge()
	_, stop := fakeApp(t, b)
	defer stop()
	e := NewExecutor(b, func() (llm.Provider, error) { return &scripted{responses: []llm.Response{{Text: "ok"}}}, nil }, nil, 10)
	e.busy <- struct{}{} // another task holds the slot
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	sink := &fakeSink{}
	go func() { done <- e.Run(ctx, executor.Request{TaskID: "t2"}, sink) }()
	cancel()
	if err := <-done; err != context.Canceled {
		t.Fatalf("err = %v", err)
	}
	if len(sink.asked) != 0 || sink.events[0].Type != "executor.waiting" {
		t.Fatalf("asked = %v events = %v", sink.asked, sink.events)
	}
}

func TestTypeLengthLimit(t *testing.T) {
	long := strings.Repeat("字", maxTypeLength+1)
	p := &scripted{responses: []llm.Response{call(`{"action":"type","text":"` + long + `"}`), {Text: "ok"}}}
	actions := run(t, p, &fakeSink{}, false, true)
	if strings.Join(actions, ",") != "release" || !strings.Contains(p.requests[1].Messages[2].Content, "longer than") {
		t.Fatalf("actions = %v", actions)
	}
}

func TestPerform(t *testing.T) {
	b := NewBridge()
	actions, stop := fakeApp(t, b)
	defer stop()
	enabled := true
	e := NewExecutor(b, nil, nil, 10).WithEnabled(func() bool { return enabled })
	sink := &fakeSink{}

	text, images, err := e.Perform(context.Background(), "ext", `{"action":"click","x":1,"y":2}`, sink)
	if err != nil || len(images) != 1 || !strings.Contains(text, "Screenshot") {
		t.Fatalf("text = %q images = %d err = %v", text, len(images), err)
	}
	if strings.Join(*actions, ",") != "click" || strings.Join(sink.asked, ",") != "computer:Clicking" {
		t.Fatalf("actions = %v asked = %v", *actions, sink.asked)
	}

	e.busy <- struct{}{}
	if _, _, err := e.Perform(context.Background(), "ext", `{"action":"screenshot"}`, sink); err == nil || !strings.Contains(err.Error(), "another task") {
		t.Fatalf("busy err = %v", err)
	}
	<-e.busy

	enabled = false
	if _, _, err := e.Perform(context.Background(), "ext", `{"action":"screenshot"}`, sink); err == nil || !strings.Contains(err.Error(), "turned off") {
		t.Fatalf("disabled err = %v", err)
	}
}
