package llm

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// anthropicProvider speaks the Anthropic Messages API.
type anthropicProvider struct{ client }

func (p *anthropicProvider) Stream(ctx context.Context, req Request, onDelta func(string) error) (Response, error) {
	maxTokens := req.MaxTokens
	if maxTokens <= 0 {
		maxTokens = 1024
	}
	body := map[string]any{
		"model":       p.model,
		"messages":    anthropicMessages(req.Messages),
		"max_tokens":  maxTokens,
		"temperature": req.Temperature,
		"stream":      true,
	}
	if req.System != "" {
		body["system"] = req.System
	}
	if len(req.Tools) > 0 {
		tools := make([]map[string]any, 0, len(req.Tools))
		for _, t := range req.Tools {
			tools = append(tools, map[string]any{"name": t.Name, "description": t.Description, "input_schema": t.Parameters})
		}
		body["tools"] = tools
	}
	headers := map[string]string{
		"x-api-key":         p.apiKey,
		"anthropic-version": "2023-06-01",
	}

	var text strings.Builder
	calls := map[int]*ToolCall{}
	err := p.postSSE(ctx, p.baseURL+"/messages", headers, body, func(data []byte) error {
		var event struct {
			Type         string `json:"type"`
			Index        int    `json:"index"`
			ContentBlock struct {
				Type string `json:"type"`
				ID   string `json:"id"`
				Name string `json:"name"`
			} `json:"content_block"`
			Delta struct {
				Type        string `json:"type"`
				Text        string `json:"text"`
				PartialJSON string `json:"partial_json"`
			} `json:"delta"`
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal(data, &event); err != nil {
			return err
		}
		switch event.Type {
		case "content_block_start":
			if event.ContentBlock.Type == "tool_use" {
				calls[event.Index] = &ToolCall{ID: event.ContentBlock.ID, Name: event.ContentBlock.Name}
			}
		case "content_block_delta":
			switch event.Delta.Type {
			case "text_delta":
				if event.Delta.Text != "" {
					text.WriteString(event.Delta.Text)
					return onDelta(event.Delta.Text)
				}
			case "input_json_delta":
				if call := calls[event.Index]; call != nil {
					call.Arguments += event.Delta.PartialJSON
				}
			}
		case "error":
			return fmt.Errorf("anthropic stream error: %s", event.Error.Message)
		}
		return nil
	})
	if err != nil {
		return Response{}, err
	}
	return Response{
		Text:      strings.TrimSpace(text.String()),
		ToolCalls: orderedCalls(calls),
		Model:     p.model,
		Provider:  p.name,
	}, nil
}

// anthropicMessages converts to content blocks. Consecutive tool results are
// merged into one user message, as the API requires.
func anthropicMessages(messages []Message) []map[string]any {
	out := make([]map[string]any, 0, len(messages))
	for _, m := range messages {
		switch {
		case m.Role == "tool":
			block := map[string]any{"type": "tool_result", "tool_use_id": m.ToolCallID, "content": m.Content}
			if n := len(out); n > 0 && out[n-1]["role"] == "user" {
				if blocks, ok := out[n-1]["content"].([]map[string]any); ok && len(blocks) > 0 && blocks[0]["type"] == "tool_result" {
					out[n-1]["content"] = append(blocks, block)
					continue
				}
			}
			out = append(out, map[string]any{"role": "user", "content": []map[string]any{block}})
		case len(m.ToolCalls) > 0:
			blocks := []map[string]any{}
			if m.Content != "" {
				blocks = append(blocks, map[string]any{"type": "text", "text": m.Content})
			}
			for _, c := range m.ToolCalls {
				blocks = append(blocks, map[string]any{"type": "tool_use", "id": c.ID, "name": c.Name, "input": json.RawMessage(jsonObject(c.Arguments))})
			}
			out = append(out, map[string]any{"role": "assistant", "content": blocks})
		default:
			out = append(out, map[string]any{"role": m.Role, "content": m.Content})
		}
	}
	return out
}
