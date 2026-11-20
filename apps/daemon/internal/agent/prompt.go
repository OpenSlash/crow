package agent

import (
	"encoding/json"
	"strings"

	"github.com/crow/crow/apps/daemon/internal/llm"
)

const basePrompt = `You are Crow, a macOS-native voice-first assistant.
Answer directly and concisely in the user's language.
When a user asks for local file edits, coding, terminal work, browser work, mail/calendar actions, or long-running execution, explain the intended result and mark that it should be delegated to a local executor.
Do not pretend that you performed local actions unless tool output was provided in the conversation.`

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

// The keyword routing below mirrors crow-cloud. Phase 1 replaces it with a
// delegate_to_codex tool call.

func shouldDelegateInput(req RespondRequest) bool {
	return req.NeedExecutor || containsExecutorKeyword(strings.ToLower(strings.TrimSpace(req.Input)))
}

var executorKeywords = []string{
	"codex", "代码", "仓库", "文件", "终端", "命令", "执行", "运行", "修复", "实现", "开发", "测试",
	"浏览", "网页", "调研", "搜索", "邮件", "email", "calendar", "日历", "browser", "repo", "terminal",
	"run ", "execute", "implement", "debug", "fix", "write file", "edit file", "open browser",
}

func containsExecutorKeyword(text string) bool {
	for _, keyword := range executorKeywords {
		if strings.Contains(text, keyword) {
			return true
		}
	}
	return false
}

func inferExecutorHint(text string) string {
	text = strings.ToLower(text)
	switch {
	case strings.Contains(text, "codex") || strings.Contains(text, "code") || strings.Contains(text, "repo") || strings.Contains(text, "terminal"):
		return "codex"
	case strings.Contains(text, "browser") || strings.Contains(text, "web") || strings.Contains(text, "research"):
		return "browser"
	case strings.Contains(text, "mail") || strings.Contains(text, "email"):
		return "email"
	default:
		return "local"
	}
}

func handoffText(hint string) string {
	switch hint {
	case "codex":
		return "我交给 Codex 处理。"
	case "browser":
		return "我交给浏览器执行器处理。"
	case "email":
		return "我交给邮件执行器处理。"
	default:
		return "我交给本地执行器处理。"
	}
}
