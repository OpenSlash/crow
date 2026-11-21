package agent

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/crow/crow/apps/daemon/internal/llm"
)

const basePrompt = `You are Crow, a macOS-native voice-first assistant.
Answer directly and concisely in the user's language; replies are often spoken aloud.
Use the provided tools when a request needs them. For local files, code, the terminal or long-running work, call delegate_to_codex instead of answering. To act in an app on screen, call use_computer.
Do not claim you performed local actions unless a tool result says so.
User messages usually come from speech recognition: read through misheard words and homophones (you run on the user's Mac, so prefer the computer meaning: 瓷盘 → 磁盘, 内存条 stays 内存条), and when the user corrects themselves ("不对，…", "我是说…", "I mean…") act on the corrected version. A message may also correct, complete or follow up the previous turn; combine them into one request. When handing off, write a task that includes this context.`

// now is the clock; tests replace it.
var now = time.Now

func systemPrompt(req RespondRequest) string {
	current := now()
	// The current time lets the model resolve "at 3 pm" or "tomorrow".
	prompt := basePrompt + "\n\nCurrent local time: " + current.Format("Monday 2006-01-02 15:04 MST (UTC-07:00)") + "."
	if req.Mode != "" || len(req.Context) > 0 {
		contextJSON, _ := json.Marshal(req.Context)
		prompt += "\n\nmode=" + strings.TrimSpace(req.Mode) + "\ncontext=" + string(contextJSON)
	}
	return prompt
}

func buildMessages(req RespondRequest) []llm.Message {
	messages := make([]llm.Message, 0, len(req.Messages)+1)
	for _, m := range req.Messages {
		content := strings.TrimSpace(m.Content)
		if content == "" {
			continue
		}
		role := strings.ToLower(strings.TrimSpace(m.Role))
		if role != "assistant" {
			role = "user"
		}
		messages = append(messages, llm.Message{Role: role, Content: content})
	}
	if input := strings.TrimSpace(req.Input); input != "" {
		messages = append(messages, llm.Message{Role: "user", Content: input})
	}
	return messages
}

func handoffText(executor string) string {
	switch executor {
	case "codex":
		return "我交给 Codex 处理。"
	case "computer":
		return "我来操作电脑。"
	}
	return "我交给本地执行器处理。"
}
