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
}

// ProviderFunc returns the provider to use for a request. It is called per
// request so settings changes apply without restarting the daemon.
type ProviderFunc func() (llm.Provider, error)

type Handler struct {
	provider ProviderFunc
}

func NewHandler(provider ProviderFunc) *Handler {
	return &Handler{provider: provider}
}

func (h *Handler) Respond(ctx context.Context, req RespondRequest, onDelta func(string) error) (RespondResult, error) {
	if shouldDelegateInput(req) {
		hint := inferExecutorHint(req.Input)
		text := handoffText(hint)
		if err := onDelta(text); err != nil {
			return RespondResult{}, err
		}
		return RespondResult{Text: text, Provider: "crow-router", NeedExecutor: true, ExecutorHint: hint}, nil
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
	resp, err := provider.Stream(ctx, llm.Request{
		System:      systemPrompt(req),
		Messages:    buildMessages(req),
		MaxTokens:   maxTokens,
		Temperature: temperature,
	}, onDelta)
	if err != nil {
		return RespondResult{}, err
	}
	result := RespondResult{Text: resp.Text, Model: resp.Model, Provider: resp.Provider}
	if containsExecutorKeyword(strings.ToLower(resp.Text)) {
		result.NeedExecutor = true
		result.ExecutorHint = inferExecutorHint(req.Input + " " + resp.Text)
	}
	return result, nil
}

// ServeRespond handles POST /v1/agent/respond.
func (h *Handler) ServeRespond(w http.ResponseWriter, r *http.Request) {
	req, ok := decode(w, r)
	if !ok {
		return
	}
	result, err := h.Respond(r.Context(), req, func(string) error { return nil })
	if err != nil {
		log.Printf("agent respond failed: %v", err)
		writeError(w, statusFor(err), err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(result)
}

// ServeRespondStream handles POST /v1/agent/respond-stream with SSE events
// "delta" {text}, "done" RespondResult and "error" {code, message}.
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

	result, err := h.Respond(r.Context(), req, func(text string) error {
		return send("delta", map[string]string{"text": text})
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
