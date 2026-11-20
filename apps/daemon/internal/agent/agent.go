// Package agent serves /v1/agent/respond and /v1/agent/respond-stream locally.
// The wire format matches crow-cloud so clients can switch between the two.
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"

	"github.com/crow/crow/apps/daemon/internal/llm"
	"github.com/crow/crow/apps/daemon/internal/memory"
)

type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type RespondRequest struct {
	Input        string         `json:"input"`
	Messages     []Message      `json:"messages"`
	Context      map[string]any `json:"context"`
	Mode         string         `json:"mode"`
	Temperature  *float64       `json:"temperature"`
	MaxTokens    int            `json:"max_tokens"`
	NeedExecutor bool           `json:"need_executor"`
}

type RespondResult struct {
	Text         string `json:"text"`
	Model        string `json:"model"`
	Provider     string `json:"provider"`
	NeedExecutor bool   `json:"need_executor"`
	ExecutorHint string `json:"executor_hint,omitempty"`
	ExecutorTask string `json:"executor_task,omitempty"`
}

// Events receives streaming output. Nil funcs are ignored.
type Events struct {
	Delta    func(text string) error
	Activity func(Activity) error
}

func (e Events) delta(text string) error {
	if e.Delta == nil {
		return nil
	}
	return e.Delta(text)
}

func (e Events) activity(a Activity) error {
	if e.Activity == nil {
		return nil
	}
	return e.Activity(a)
}

// ProviderFunc returns the provider to use for a request. It is called per
// request so settings changes apply without restarting the daemon.
type ProviderFunc func() (llm.Provider, error)

type Handler struct {
	provider      ProviderFunc
	tools         []Tool
	maxSteps      int
	memory        *memory.Store
	memoryEnabled func() bool
}

// DefaultMaxSteps caps model requests per turn.
const DefaultMaxSteps = 40

func NewHandler(provider ProviderFunc, maxSteps int, tools ...Tool) *Handler {
	if maxSteps <= 0 {
		maxSteps = DefaultMaxSteps
	}
	return &Handler{provider: provider, tools: tools, maxSteps: maxSteps}
}

// WithMemory adds long-term memory: the profile goes into the system prompt and
// the memory tools are offered, whenever enabled reports true.
func (h *Handler) WithMemory(store *memory.Store, enabled func() bool) *Handler {
	h.memory = store
	h.memoryEnabled = enabled
	return h
}

// turn returns the system prompt and tools for one request.
func (h *Handler) turn(req RespondRequest) (string, map[string]Tool, []llm.Tool) {
	system := systemPrompt(req)
	tools := h.tools
	if h.memory != nil && (h.memoryEnabled == nil || h.memoryEnabled()) {
		system += memoryPromptSection(h.memory)
		tools = append(append([]Tool{}, tools...), MemoryTools(h.memory)...)
	}
	byName := make(map[string]Tool, len(tools))
	specs := make([]llm.Tool, 0, len(tools))
	for _, t := range tools {
		spec := t.Spec()
		byName[spec.Name] = t
		specs = append(specs, spec)
	}
	return system, byName, specs
}

// Respond runs the tool loop: call the model, run requested tools, feed results
// back, until the model answers without tools, a tool hands off, or the step cap.
func (h *Handler) Respond(ctx context.Context, req RespondRequest, ev Events) (RespondResult, error) {
	if req.NeedExecutor {
		return h.handoff(RespondResult{Provider: "crow-router"}, "", Handoff{Executor: "codex", Task: strings.TrimSpace(req.Input)}, ev)
	}

	provider, err := h.provider()
	if err != nil {
		return RespondResult{}, err
	}
	temperature := 0.2
	if req.Temperature != nil {
		temperature = *req.Temperature
	}
	maxTokens := req.MaxTokens
	if maxTokens <= 0 {
		maxTokens = 900
	}
	messages := buildMessages(req)
	system, tools, specs := h.turn(req)
	base := RespondResult{Model: provider.Model(), Provider: provider.Name()}

	for step := 0; step < h.maxSteps; step++ {
		if err := ev.activity(Activity{Kind: ActivityThinking, Label: "Thinking"}); err != nil {
			return RespondResult{}, err
		}
		resp, err := provider.Stream(ctx, llm.Request{
			System:      system,
			Messages:    messages,
			Tools:       specs,
			MaxTokens:   maxTokens,
			Temperature: temperature,
		}, ev.delta)
		if err != nil {
			return RespondResult{}, err
		}
		if len(resp.ToolCalls) == 0 {
			base.Text = resp.Text
			return base, nil
		}

		messages = append(messages, llm.Message{Role: "assistant", Content: resp.Text, ToolCalls: resp.ToolCalls})
		for _, call := range resp.ToolCalls {
			result := runTool(ctx, tools, call, ev)
			if result.Handoff != nil {
				return h.handoff(base, resp.Text, *result.Handoff, ev)
			}
			messages = append(messages, llm.Message{Role: "tool", ToolCallID: call.ID, Content: result.Content})
		}
	}

	base.Text = "这个任务步骤太多，我先停下了。需要的话让我继续。"
	return base, ev.delta(base.Text)
}

func runTool(ctx context.Context, tools map[string]Tool, call llm.ToolCall, ev Events) ToolResult {
	tool, ok := tools[call.Name]
	if !ok {
		return ToolResult{Content: "Error: unknown tool " + call.Name}
	}
	_ = ev.activity(tool.Activity())
	result, err := tool.Run(ctx, json.RawMessage(call.Arguments))
	if err != nil {
		log.Printf("agent tool %s failed: %v", call.Name, err)
		return ToolResult{Content: "Error: " + err.Error()}
	}
	return result
}

// handoff ends the turn. spoken is text the model already streamed, if any.
func (h *Handler) handoff(base RespondResult, spoken string, handoff Handoff, ev Events) (RespondResult, error) {
	base.NeedExecutor = true
	base.ExecutorHint = handoff.Executor
	base.ExecutorTask = handoff.Task
	base.Text = strings.TrimSpace(spoken)
	if base.Text == "" {
		base.Text = handoffText(handoff.Executor)
		if err := ev.delta(base.Text); err != nil {
			return RespondResult{}, err
		}
	}
	return base, nil
}

// ServeRespond handles POST /v1/agent/respond.
func (h *Handler) ServeRespond(w http.ResponseWriter, r *http.Request) {
	req, ok := decode(w, r)
	if !ok {
		return
	}
	result, err := h.Respond(r.Context(), req, Events{})
	if err != nil {
		log.Printf("agent respond failed: %v", err)
		writeError(w, statusFor(err), err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(result)
}

// ServeRespondStream handles POST /v1/agent/respond-stream with SSE events
// "delta" {text}, "activity" {kind, label}, "done" RespondResult and "error" {code, message}.
func (h *Handler) ServeRespondStream(w http.ResponseWriter, r *http.Request) {
	req, ok := decode(w, r)
	if !ok {
		return
	}
	flusher, _ := w.(http.Flusher)
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)

	send := func(event string, payload any) error {
		data, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		if _, err := w.Write([]byte("event: " + event + "\ndata: " + string(data) + "\n\n")); err != nil {
			return err
		}
		if flusher != nil {
			flusher.Flush()
		}
		return nil
	}

	result, err := h.Respond(r.Context(), req, Events{
		Delta:    func(text string) error { return send("delta", map[string]string{"text": text}) },
		Activity: func(a Activity) error { return send("activity", a) },
	})
	if err != nil {
		log.Printf("agent stream failed: %v", err)
		_ = send("error", map[string]string{"code": errorCode(err), "message": err.Error()})
		return
	}
	_ = send("done", result)
}

func decode(w http.ResponseWriter, r *http.Request) (RespondRequest, bool) {
	var req RespondRequest
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, errors.New("method not allowed"))
		return req, false
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, err)
		return req, false
	}
	if strings.TrimSpace(req.Input) == "" && len(req.Messages) == 0 {
		writeError(w, http.StatusBadRequest, errors.New("input or messages is required"))
		return req, false
	}
	return req, true
}

func writeError(w http.ResponseWriter, status int, err error) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error": map[string]string{"code": errorCode(err), "message": err.Error()},
	})
}

func statusFor(err error) int {
	if errors.Is(err, llm.ErrNotConfigured) {
		return http.StatusPreconditionFailed
	}
	return http.StatusBadGateway
}

func errorCode(err error) string {
	if errors.Is(err, llm.ErrNotConfigured) {
		return "provider_not_configured"
	}
	return "agent_provider_error"
}
