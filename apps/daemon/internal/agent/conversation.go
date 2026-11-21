package agent

import (
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/crow/crow/apps/daemon/internal/llm"
)

// Conversation is the short-term context of the voice conversation: recent user
// and assistant turns, plus the results of tasks handed off from them. It lets a
// follow-up ("use a command for it") build on the previous turn. It is kept in
// memory and forgotten after a pause, so an old topic does not leak into a new one.
type Conversation struct {
	mu       sync.Mutex
	messages []llm.Message
	lastAt   time.Time
	idle     time.Duration
	max      int
}

const (
	// DefaultConversationIdle is the pause after which the context is forgotten.
	DefaultConversationIdle = 15 * time.Minute
	conversationMaxMessages = 24
	conversationMaxRunes    = 2000
)

func NewConversation(idle time.Duration) *Conversation {
	if idle <= 0 {
		idle = DefaultConversationIdle
	}
	return &Conversation{idle: idle, max: conversationMaxMessages}
}

// History returns the recent messages, oldest first.
func (c *Conversation) History() []llm.Message {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.expireLocked()
	return append([]llm.Message(nil), c.messages...)
}

// Add appends text messages. Consecutive messages of one role are merged, so a
// task result joins the hand-off reply it belongs to.
func (c *Conversation) Add(role, text string) {
	text = strings.TrimSpace(text)
	if text == "" {
		return
	}
	if utf8.RuneCountInString(text) > conversationMaxRunes {
		text = string([]rune(text)[:conversationMaxRunes]) + "…"
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.expireLocked()
	c.lastAt = now()
	if n := len(c.messages); n > 0 && c.messages[n-1].Role == role {
		c.messages[n-1].Content += "\n" + text
		return
	}
	c.messages = append(c.messages, llm.Message{Role: role, Content: text})
	if len(c.messages) > c.max {
		c.messages = c.messages[len(c.messages)-c.max:]
	}
	// Providers expect the conversation to start with the user.
	for len(c.messages) > 0 && c.messages[0].Role != "user" {
		c.messages = c.messages[1:]
	}
}

func (c *Conversation) expireLocked() {
	if !c.lastAt.IsZero() && now().Sub(c.lastAt) > c.idle {
		c.messages = nil
	}
}
