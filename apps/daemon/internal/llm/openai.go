package llm

import (
	"context"
	"encoding/json"
	"strings"
)

// openAIProvider speaks the OpenAI Chat Completions API, which most providers implement.
type openAIProvider struct{ client }

func (p *openAIProvider) Stream(ctx context.Context, req Request, onDelta func(string) error) (Response, error) {
	messages := make([]map[string]string, 0, len(req.Messages)+1)
	if req.System != "" {
		messages = append(messages, map[string]string{"role": "system", "content": req.System})
	}
	for _, m := range req.Messages {
		messages = append(messages, map[string]string{"role": m.Role, "content": m.Content})
	}
	body := map[string]any{
		"model":       p.model,
		"messages":    messages,
		"temperature": req.Temperature,
		"stream":      true,
	}
	if req.MaxTokens > 0 {
		body["max_tokens"] = req.MaxTokens
	}
	headers := map[string]string{}
	if p.apiKey != "" {
		headers["Authorization"] = "Bearer " + p.apiKey
	}

	var text strings.Builder
	err := p.postSSE(ctx, p.baseURL+"/chat/completions", headers, body, func(data []byte) error {
		var event struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal(data, &event); err != nil {
			return err
		}
		for _, choice := range event.Choices {
			if chunk := choice.Delta.Content; chunk != "" {
				text.WriteString(chunk)
				if err := onDelta(chunk); err != nil {
					return err
				}
			}
		}
		return nil
	})
	if err != nil {
		return Response{}, err
	}
	return Response{Text: strings.TrimSpace(text.String()), Model: p.model, Provider: p.name}, nil
}
