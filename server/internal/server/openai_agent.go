package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

type AgentMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type AgentRespondRequest struct {
	Input        string                 `json:"input"`
	Messages     []AgentMessage         `json:"messages"`
	Context      map[string]interface{} `json:"context"`
	Mode         string                 `json:"mode"`
	Model        string                 `json:"model"`
	Stream       bool                   `json:"stream"`
	Temperature  *float64               `json:"temperature"`
	MaxTokens    int                    `json:"max_tokens"`
	NeedExecutor bool                   `json:"need_executor"`
}

type AgentRespondResult struct {
	Text         string                 `json:"text"`
	Model        string                 `json:"model"`
	Provider     string                 `json:"provider"`
	NeedExecutor bool                   `json:"need_executor"`
	ExecutorHint string                 `json:"executor_hint,omitempty"`
	Usage        map[string]interface{} `json:"usage,omitempty"`
}

type AgentStreamDelta struct {
	Text string `json:"text"`
}

type AgentStreamDone struct {
	Text         string `json:"text"`
	Model        string `json:"model"`
	Provider     string `json:"provider"`
	NeedExecutor bool   `json:"need_executor"`
	ExecutorHint string `json:"executor_hint,omitempty"`
}

func (a *API) respondWithOpenAI(ctx context.Context, req AgentRespondRequest) (AgentRespondResult, error) {
	if strings.TrimSpace(a.cfg.OpenAIAPIKey) == "" {
		return AgentRespondResult{}, fmt.Errorf("OpenAI API key is not configured")
	}

	model := firstNonEmptyString(req.Model, a.cfg.OpenAIAgentModel, "gpt-4.1-mini")
	if shouldDelegateInputToExecutor(req) {
		return AgentRespondResult{
			Text:         executorHandoffText(req),
			Model:        model,
			Provider:     "crow-router",
			NeedExecutor: true,
			ExecutorHint: inferExecutorHint(req, ""),
		}, nil
	}

	messages := buildAgentMessages(req)
	temperature := 0.2
	if req.Temperature != nil {
		temperature = *req.Temperature
	}
	maxTokens := req.MaxTokens
	if maxTokens <= 0 {
		maxTokens = 900
	}

	payload, err := json.Marshal(map[string]interface{}{
		"model":       model,
		"messages":    messages,
		"temperature": temperature,
		"max_tokens":  maxTokens,
		"stream":      false,
	})
	if err != nil {
		return AgentRespondResult{}, err
	}

	url := strings.TrimRight(firstNonEmptyString(a.cfg.OpenAIBaseURL, "https://api.openai.com"), "/") + "/v1/chat/completions"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return AgentRespondResult{}, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+strings.TrimSpace(a.cfg.OpenAIAPIKey))
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := voiceHTTPClient().Do(httpReq)
	if err != nil {
		return AgentRespondResult{}, err
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return AgentRespondResult{}, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return AgentRespondResult{}, fmt.Errorf("OpenAI agent failed with status %d: %s", resp.StatusCode, compactErrorBody(data))
	}

	var decoded struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage map[string]interface{} `json:"usage"`
	}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return AgentRespondResult{}, err
	}
	if len(decoded.Choices) == 0 {
		return AgentRespondResult{}, fmt.Errorf("OpenAI agent returned no choices")
	}

	text := strings.TrimSpace(decoded.Choices[0].Message.Content)
	result := AgentRespondResult{
		Text:         text,
		Model:        model,
		Provider:     "openai",
		NeedExecutor: shouldDelegateToExecutor(req, text),
		Usage:        decoded.Usage,
	}
	if result.NeedExecutor {
		result.ExecutorHint = inferExecutorHint(req, text)
	}
	return result, nil
}

func (a *API) streamRespondWithOpenAI(ctx context.Context, req AgentRespondRequest, onDelta func(AgentStreamDelta) error) (AgentStreamDone, error) {
	if strings.TrimSpace(a.cfg.OpenAIAPIKey) == "" {
		return AgentStreamDone{}, fmt.Errorf("OpenAI API key is not configured")
	}

	model := firstNonEmptyString(req.Model, a.cfg.OpenAIAgentModel, "gpt-4.1-mini")
	if shouldDelegateInputToExecutor(req) {
		text := executorHandoffText(req)
		if err := onDelta(AgentStreamDelta{Text: text}); err != nil {
			return AgentStreamDone{}, err
		}
		return AgentStreamDone{
			Text:         text,
			Model:        model,
			Provider:     "crow-router",
			NeedExecutor: true,
			ExecutorHint: inferExecutorHint(req, ""),
		}, nil
	}

	messages := buildAgentMessages(req)
	temperature := 0.2
	if req.Temperature != nil {
		temperature = *req.Temperature
	}
	maxTokens := req.MaxTokens
	if maxTokens <= 0 {
		maxTokens = 900
	}

	payload, err := json.Marshal(map[string]interface{}{
		"model":       model,
		"messages":    messages,
		"temperature": temperature,
		"max_tokens":  maxTokens,
		"stream":      true,
	})
	if err != nil {
		return AgentStreamDone{}, err
	}

	url := strings.TrimRight(firstNonEmptyString(a.cfg.OpenAIBaseURL, "https://api.openai.com"), "/") + "/v1/chat/completions"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return AgentStreamDone{}, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+strings.TrimSpace(a.cfg.OpenAIAPIKey))
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")

	resp, err := voiceHTTPClient().Do(httpReq)
	if err != nil {
		return AgentStreamDone{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		return AgentStreamDone{}, fmt.Errorf("OpenAI agent stream failed with status %d: %s", resp.StatusCode, compactErrorBody(data))
	}

	var builder strings.Builder
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 2*1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, ":") {
			continue
		}
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "[DONE]" {
			break
		}

		var event struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(data), &event); err != nil {
			return AgentStreamDone{}, err
		}
		for _, choice := range event.Choices {
			text := choice.Delta.Content
			if text == "" {
				continue
			}
			builder.WriteString(text)
			if err := onDelta(AgentStreamDelta{Text: text}); err != nil {
				return AgentStreamDone{}, err
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return AgentStreamDone{}, err
	}

	text := strings.TrimSpace(builder.String())
	done := AgentStreamDone{
		Text:         text,
		Model:        model,
		Provider:     "openai",
		NeedExecutor: shouldDelegateToExecutor(req, text),
	}
	if done.NeedExecutor {
		done.ExecutorHint = inferExecutorHint(req, text)
	}
	return done, nil
}

func buildAgentMessages(req AgentRespondRequest) []map[string]string {
	messages := []map[string]string{{
		"role": "system",
		"content": strings.TrimSpace(`You are Crow, a macOS-native voice-first assistant.
Answer directly and concisely.
When a user asks for local file edits, coding, terminal work, browser work, mail/calendar actions, or long-running execution, explain the intended result and mark that it should be delegated to a local executor.
Do not pretend that you performed local actions unless tool output was provided in the conversation.`),
	}}

	if req.Mode != "" || len(req.Context) > 0 {
		contextBytes, _ := json.Marshal(req.Context)
		messages = append(messages, map[string]string{
			"role":    "system",
			"content": "mode=" + strings.TrimSpace(req.Mode) + "\ncontext=" + string(contextBytes),
		})
	}

	for _, message := range req.Messages {
		role := strings.ToLower(strings.TrimSpace(message.Role))
		if role != "system" && role != "assistant" && role != "user" {
			role = "user"
		}
		content := strings.TrimSpace(message.Content)
		if content == "" {
			continue
		}
		messages = append(messages, map[string]string{
			"role":    role,
			"content": content,
		})
	}

	input := strings.TrimSpace(req.Input)
	if input != "" {
		messages = append(messages, map[string]string{
			"role":    "user",
			"content": input,
		})
	}
	return messages
}

func inferExecutorHint(req AgentRespondRequest, text string) string {
	joined := strings.ToLower(req.Input + " " + text)
	switch {
	case strings.Contains(joined, "codex") || strings.Contains(joined, "code") || strings.Contains(joined, "repo") || strings.Contains(joined, "terminal"):
		return "codex"
	case strings.Contains(joined, "browser") || strings.Contains(joined, "web") || strings.Contains(joined, "research"):
		return "browser"
	case strings.Contains(joined, "mail") || strings.Contains(joined, "email"):
		return "email"
	default:
		return "local"
	}
}

func shouldDelegateToExecutor(req AgentRespondRequest, text string) bool {
	if shouldDelegateInputToExecutor(req) {
		return true
	}
	joined := strings.ToLower(strings.TrimSpace(text))
	return containsExecutorKeyword(joined)
}

func shouldDelegateInputToExecutor(req AgentRespondRequest) bool {
	if req.NeedExecutor {
		return true
	}
	joined := strings.ToLower(strings.TrimSpace(req.Input))
	return containsExecutorKeyword(joined)
}

func containsExecutorKeyword(joined string) bool {
	keywords := []string{
		"codex", "代码", "仓库", "文件", "终端", "命令", "执行", "运行", "修复", "实现", "开发", "测试",
		"浏览", "网页", "调研", "搜索", "邮件", "email", "calendar", "日历", "browser", "repo", "terminal",
		"run ", "execute", "implement", "debug", "fix", "write file", "edit file", "open browser",
	}
	for _, keyword := range keywords {
		if strings.Contains(joined, keyword) {
			return true
		}
	}
	return false
}

func executorHandoffText(req AgentRespondRequest) string {
	switch inferExecutorHint(req, "") {
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
