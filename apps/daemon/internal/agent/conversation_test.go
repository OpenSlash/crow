package agent

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/crow/crow/apps/daemon/internal/llm"
)

type recordingProvider struct {
	replies []string
	seen    [][]llm.Message
}

func (p *recordingProvider) Name() string  { return "test" }
func (p *recordingProvider) Model() string { return "test" }
func (p *recordingProvider) Stream(_ context.Context, req llm.Request, _ func(string) error) (llm.Response, error) {
	p.seen = append(p.seen, append([]llm.Message(nil), req.Messages...))
	reply := p.replies[0]
	p.replies = p.replies[1:]
	return llm.Response{Text: reply}, nil
}

func TestFollowUpSeesPreviousTurn(t *testing.T) {
	p := &recordingProvider{replies: []string{"你想查询什么？", "好的，用 df -h 查看磁盘。"}}
	conv := NewConversation(time.Minute)
	h := NewHandler(func() (llm.Provider, error) { return p, nil }, 4).WithConversation(conv)

	if _, err := h.Respond(context.Background(), RespondRequest{Input: "查询瓷盘"}, Events{}); err != nil {
		t.Fatal(err)
	}
	conv.Add("assistant", "[Task result] 剩余 120 GB")
	if _, err := h.Respond(context.Background(), RespondRequest{Input: "可以用命令查询"}, Events{}); err != nil {
		t.Fatal(err)
	}
	second := p.seen[1]
	if len(second) != 3 || second[0].Content != "查询瓷盘" || !strings.Contains(second[1].Content, "[Task result] 剩余 120 GB") || second[2].Content != "可以用命令查询" {
		t.Fatalf("second request messages = %+v", second)
	}
}

func TestConversationExpiresAndTrims(t *testing.T) {
	current := time.Date(2026, 11, 21, 10, 0, 0, 0, time.Local)
	now = func() time.Time { return current }
	defer func() { now = time.Now }()

	c := NewConversation(time.Minute)
	for i := 0; i < 40; i++ {
		c.Add("user", "q")
		c.Add("assistant", "a")
	}
	if h := c.History(); len(h) != conversationMaxMessages || h[0].Role != "user" {
		t.Fatalf("history len %d first %q", len(h), h[0].Role)
	}
	current = current.Add(2 * time.Minute)
	if h := c.History(); len(h) != 0 {
		t.Fatalf("expected empty history after idle, got %d", len(h))
	}
}

func TestClientHistoryBypassesConversation(t *testing.T) {
	p := &recordingProvider{replies: []string{"ok"}}
	conv := NewConversation(time.Minute)
	conv.Add("user", "old")
	h := NewHandler(func() (llm.Provider, error) { return p, nil }, 4).WithConversation(conv)
	_, err := h.Respond(context.Background(), RespondRequest{Messages: []Message{{Role: "user", Content: "mine"}}}, Events{})
	if err != nil {
		t.Fatal(err)
	}
	if len(p.seen[0]) != 1 || p.seen[0][0].Content != "mine" {
		t.Fatalf("messages = %+v", p.seen[0])
	}
	if len(conv.History()) != 1 {
		t.Fatal("client-managed request must not change the conversation")
	}
}
