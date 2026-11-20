package llm

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"sync"
)

// openAIProvider speaks the OpenAI Chat Completions API, which most providers implement.
type openAIProvider struct{ client }

// openAIQuirks are request changes a model turned out to need. Newer OpenAI models
// reject max_tokens, or tools together with reasoning in Chat Completions, while
// other OpenAI-compatible providers still expect the classic fields. Rather than
// keeping a list of model names, the provider learns them from the 400 errors,
// once per base URL and model.
type openAIQuirks struct {
	completionTokens bool // send max_completion_tokens instead of max_tokens
	noReasoning      bool // send reasoning_effort "none" so tools are allowed
	noTemperature    bool // omit temperature
	useResponses     bool // reasoning can't be turned off: tools need the Responses API
}

var learnedQuirks sync.Map // baseURL|model -> openAIQuirks

// learn updates q from a request error and reports whether a retry may succeed.
func (q *openAIQuirks) learn(err error) bool {
	msg := err.Error()
	switch {
	case !q.completionTokens && strings.Contains(msg, "max_completion_tokens"):
		q.completionTokens = true
	case !q.noReasoning && strings.Contains(msg, "reasoning_effort to 'none'"):
		q.noReasoning = true
	case !q.noTemperature && strings.Contains(msg, "'temperature'"):
		q.noTemperature = true
	case !q.useResponses && q.noReasoning && strings.Contains(msg, "reasoning_effort") && strings.Contains(msg, "'none'"):
		// "set reasoning_effort to 'none'" was not enough: the model keeps reasoning.
		q.useResponses = true
	default:
		return false
	}
	return true
}

func (p *openAIProvider) Stream(ctx context.Context, req Request, onDelta func(string) error) (Response, error) {
	key := p.baseURL + "|" + p.model
	var quirks openAIQuirks
	if v, ok := learnedQuirks.Load(key); ok {
		quirks = v.(openAIQuirks)
	}
	// CROW_LLM_API forces an API: "responses" or "chat". Otherwise it is learned.
	api := strings.ToLower(env("CROW_LLM_API"))
	for attempt := 0; ; attempt++ {
		streamed := false
		track := func(text string) error {
			streamed = true
			return onDelta(text)
		}
		var resp Response
		var err error
		if api == "responses" || (api != "chat" && quirks.useResponses) {
			resp, err = p.streamResponses(ctx, req, quirks, track)
		} else {
			resp, err = p.streamOnce(ctx, req, quirks, track)
		}
		if err == nil || streamed || attempt >= 4 || !quirks.learn(err) {
			return resp, err
		}
		learnedQuirks.Store(key, quirks)
	}
}

func (p *openAIProvider) streamOnce(ctx context.Context, req Request, quirks openAIQuirks, onDelta func(string) error) (Response, error) {
	body := map[string]any{
		"model":    p.model,
		"messages": openAIMessages(req),
		"stream":   true,
	}
	if !quirks.noTemperature {
		body["temperature"] = req.Temperature
	}
	if quirks.noReasoning {
		body["reasoning_effort"] = "none"
	}
	if req.MaxTokens > 0 {
		if quirks.completionTokens {
			body["max_completion_tokens"] = req.MaxTokens
		} else {
			body["max_tokens"] = req.MaxTokens
		}
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
	// Tool messages can't carry images, so images follow the tool results as a user message.
	var pendingImages []map[string]any
	flushImages := func() {
		if len(pendingImages) > 0 {
			content := append([]map[string]any{{"type": "text", "text": "Images returned by the tool calls above."}}, pendingImages...)
			messages = append(messages, map[string]any{"role": "user", "content": content})
			pendingImages = nil
		}
	}
	for _, m := range req.Messages {
		if m.Role != "tool" {
			flushImages()
		}
		switch {
		case m.Role == "tool":
			messages = append(messages, map[string]any{"role": "tool", "tool_call_id": m.ToolCallID, "content": m.Content})
			for _, img := range m.Images {
				pendingImages = append(pendingImages, map[string]any{
					"type":      "image_url",
					"image_url": map[string]any{"url": "data:" + img.MediaType + ";base64," + img.base64()},
				})
			}
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
	flushImages()
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
