package llm

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
)

// openAIProvider speaks the OpenAI Chat Completions API, which most providers implement.
type openAIProvider struct{ client }

func (p *openAIProvider) Stream(ctx context.Context, req Request, onDelta func(string) error) (Response, error) {
	body := map[string]any{
		"model":       p.model,
		"messages":    openAIMessages(req),
		"temperature": req.Temperature,
		"stream":      true,
	}
	if req.MaxTokens > 0 {
		body["max_tokens"] = req.MaxTokens
	}
	if len(req.Tools) > 0 {
		tools := make([]map[string]any, 0, len(req.Tools))
		for _, t := range req.Tools {
			tools = append(tools, map[string]any{
				"type": "function",
				"function": map[string]any{
					"name":        t.Name,
					"description": t.Description,
					"parameters":  t.Parameters,
				},
			})
		}
		body["tools"] = tools
	}
	headers := map[string]string{}
	if p.apiKey != "" {
		headers["Authorization"] = "Bearer " + p.apiKey
	}

	var text strings.Builder
	calls := map[int]*ToolCall{} // tool call fragments arrive keyed by index
	err := p.postSSE(ctx, p.baseURL+"/chat/completions", headers, body, func(data []byte) error {
		var event struct {
			Choices []struct {
				Delta struct {
					Content   string `json:"content"`
					ToolCalls []struct {
						Index    int    `json:"index"`
						ID       string `json:"id"`
						Function struct {
							Name      string `json:"name"`
							Arguments string `json:"arguments"`
						} `json:"function"`
					} `json:"tool_calls"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal(data, &event); err != nil {
			return err
		}
		for _, choice := range event.Choices {
			for _, tc := range choice.Delta.ToolCalls {
				call := calls[tc.Index]
				if call == nil {
					call = &ToolCall{}
					calls[tc.Index] = call
				}
				if tc.ID != "" {
					call.ID = tc.ID
				}
				call.Name += tc.Function.Name
				call.Arguments += tc.Function.Arguments
			}
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
	return Response{
		Text:      strings.TrimSpace(text.String()),
		ToolCalls: orderedCalls(calls),
		Model:     p.model,
		Provider:  p.name,
	}, nil
}

func openAIMessages(req Request) []map[string]any {
	messages := make([]map[string]any, 0, len(req.Messages)+1)
	if req.System != "" {
		messages = append(messages, map[string]any{"role": "system", "content": req.System})
	}
	for _, m := range req.Messages {
		switch {
		case m.Role == "tool":
			messages = append(messages, map[string]any{"role": "tool", "tool_call_id": m.ToolCallID, "content": m.Content})
		case len(m.ToolCalls) > 0:
			calls := make([]map[string]any, 0, len(m.ToolCalls))
			for _, c := range m.ToolCalls {
				calls = append(calls, map[string]any{
					"id":       c.ID,
					"type":     "function",
					"function": map[string]any{"name": c.Name, "arguments": jsonObject(c.Arguments)},
				})
			}
			messages = append(messages, map[string]any{"role": "assistant", "content": m.Content, "tool_calls": calls})
		default:
			messages = append(messages, map[string]any{"role": m.Role, "content": m.Content})
		}
	}
	return messages
}

func orderedCalls(calls map[int]*ToolCall) []ToolCall {
	indexes := make([]int, 0, len(calls))
	for i := range calls {
		indexes = append(indexes, i)
	}
	sort.Ints(indexes)
	out := make([]ToolCall, 0, len(calls))
	for _, i := range indexes {
		c := *calls[i]
		c.Arguments = jsonObject(c.Arguments)
		out = append(out, c)
	}
	return out
}

// jsonObject returns "{}" for empty arguments so they always parse.
func jsonObject(raw string) string {
	if strings.TrimSpace(raw) == "" {
		return "{}"
	}
	return raw
}
