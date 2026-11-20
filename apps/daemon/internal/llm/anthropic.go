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
	messages := make([]map[string]string, 0, len(req.Messages))
	for _, m := range req.Messages {
		messages = append(messages, map[string]string{"role": m.Role, "content": m.Content})
	}
	maxTokens := req.MaxTokens
	if maxTokens <= 0 {
		maxTokens = 1024
	}
	body := map[string]any{
		"model":       p.model,
		"messages":    messages,
		"max_tokens":  maxTokens,
		"temperature": req.Temperature,
		"stream":      true,
	}
	if req.System != "" {
		body["system"] = req.System
	}
	headers := map[string]string{
		"x-api-key":         p.apiKey,
		"anthropic-version": "2023-06-01",
	}

	var text strings.Builder
	err := p.postSSE(ctx, p.baseURL+"/messages", headers, body, func(data []byte) error {
		var event struct {
			Type  string `json:"type"`
			Delta struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"delta"`
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal(data, &event); err != nil {
			return err
		}
		switch event.Type {
		case "content_block_delta":
			if event.Delta.Type == "text_delta" && event.Delta.Text != "" {
				text.WriteString(event.Delta.Text)
				return onDelta(event.Delta.Text)
			}
		case "error":
			return fmt.Errorf("anthropic stream error: %s", event.Error.Message)
		}
		return nil
	})
	if err != nil {
		return Response{}, err
	}
	return Response{Text: strings.TrimSpace(text.String()), Model: p.model, Provider: p.name}, nil
}
