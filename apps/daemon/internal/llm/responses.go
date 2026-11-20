package llm

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// reasoningHeadroom is added to the output budget on the Responses API, where
// max_output_tokens also covers reasoning tokens.
const reasoningHeadroom = 2048

// streamResponses speaks OpenAI's Responses API. Models whose reasoning cannot be
// turned off only accept function tools there, not in Chat Completions.
// Requests are stateless (store: false): the whole conversation is sent each time.
func (p *openAIProvider) streamResponses(ctx context.Context, req Request, quirks openAIQuirks, onDelta func(string) error) (Response, error) {
	body := map[string]any{
		"model":  p.model,
		"input":  responsesInput(req.Messages),
		"stream": true,
		"store":  false,
	}
	if req.System != "" {
		body["instructions"] = req.System
	}
	effort := strings.ToLower(env("CROW_LLM_REASONING_EFFORT"))
	if effort == "" {
		effort = "low" // replies are usually spoken: favor speed
	}
	body["reasoning"] = map[string]any{"effort": effort}
	if req.MaxTokens > 0 {
		body["max_output_tokens"] = req.MaxTokens + reasoningHeadroom
	}
	if !quirks.noTemperature {
		body["temperature"] = req.Temperature
	}
	if len(req.Tools) > 0 {
		tools := make([]map[string]any, 0, len(req.Tools))
		for _, t := range req.Tools {
			tools = append(tools, map[string]any{
				"type":        "function",
				"name":        t.Name,
				"description": t.Description,
				"parameters":  t.Parameters,
			})
		}
		body["tools"] = tools
	}
	headers := map[string]string{}
	if p.apiKey != "" {
		headers["Authorization"] = "Bearer " + p.apiKey
	}

	var text strings.Builder
	var final []responsesItem
	var failure error
	err := p.postSSE(ctx, p.baseURL+"/responses", headers, body, func(data []byte) error {
		var event struct {
			Type     string `json:"type"`
			Delta    string `json:"delta"`
			Message  string `json:"message"`
			Response struct {
				Output []responsesItem `json:"output"`
				Error  *struct {
					Message string `json:"message"`
				} `json:"error"`
			} `json:"response"`
		}
		if err := json.Unmarshal(data, &event); err != nil {
			return nil // ignore events we do not understand
		}
		switch event.Type {
		case "response.output_text.delta":
			if event.Delta != "" {
				text.WriteString(event.Delta)
				return onDelta(event.Delta)
			}
		case "response.completed", "response.incomplete":
			final = event.Response.Output
		case "response.failed":
			if event.Response.Error != nil {
				failure = fmt.Errorf("openai response failed: %s", event.Response.Error.Message)
			} else {
				failure = fmt.Errorf("openai response failed")
			}
		case "error":
			failure = fmt.Errorf("openai response error: %s", event.Message)
		}
		return nil
	})
	if err != nil {
		return Response{}, err
	}
	if failure != nil {
		return Response{}, failure
	}

	resp := Response{Text: text.String(), Model: p.model, Provider: p.name}
	for _, item := range final {
		if item.Type == "function_call" {
			resp.ToolCalls = append(resp.ToolCalls, ToolCall{ID: item.CallID, Name: item.Name, Arguments: jsonObject(item.Arguments)})
		}
	}
	return resp, nil
}

type responsesItem struct {
	Type      string `json:"type"`
	CallID    string `json:"call_id"`
	Name      string `json:"name"`
	Arguments string `json:"arguments"`
}

// responsesInput converts the conversation to Responses input items. Tool images
// follow the tool outputs as a user message, as in Chat Completions.
func responsesInput(messages []Message) []map[string]any {
	items := make([]map[string]any, 0, len(messages))
	var pendingImages []map[string]any
	flushImages := func() {
		if len(pendingImages) > 0 {
			content := append([]map[string]any{{"type": "input_text", "text": "Images returned by the tool calls above."}}, pendingImages...)
			items = append(items, map[string]any{"role": "user", "content": content})
			pendingImages = nil
		}
	}
	for _, m := range messages {
		if m.Role != "tool" {
			flushImages()
		}
		switch {
		case m.Role == "tool":
			items = append(items, map[string]any{"type": "function_call_output", "call_id": m.ToolCallID, "output": m.Content})
			for _, img := range m.Images {
				pendingImages = append(pendingImages, map[string]any{
					"type":      "input_image",
					"image_url": "data:" + img.MediaType + ";base64," + img.base64(),
				})
			}
		case len(m.ToolCalls) > 0:
			if m.Content != "" {
				items = append(items, map[string]any{"role": "assistant", "content": m.Content})
			}
			for _, c := range m.ToolCalls {
				items = append(items, map[string]any{"type": "function_call", "call_id": c.ID, "name": c.Name, "arguments": jsonObject(c.Arguments)})
			}
		default:
			items = append(items, map[string]any{"role": m.Role, "content": m.Content})
		}
	}
	flushImages()
	return items
}
