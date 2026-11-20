package agent

import (
	"encoding/json"
	"strings"

	"github.com/crow/crow/apps/daemon/internal/llm"
)

const basePrompt = `You are Crow, a macOS-native voice-first assistant.
Answer directly and concisely in the user's language; replies are often spoken aloud.
Use the provided tools when a request needs them. For local files, code, the terminal or long-running work, call delegate_to_codex instead of answering. To act in an app on screen, call use_computer.
Do not claim you performed local actions unless a tool result says so.`

func systemPrompt(req RespondRequest) string {
	prompt := basePrompt
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
