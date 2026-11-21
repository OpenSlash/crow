package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

type RealtimeClientSecretRequest struct {
	Model        string                 `json:"model"`
	Voice        string                 `json:"voice"`
	Instructions string                 `json:"instructions"`
	Metadata     map[string]interface{} `json:"metadata"`
}

type RealtimeClientSecretResult struct {
	Provider      string                 `json:"provider"`
	Model         string                 `json:"model"`
	Voice         string                 `json:"voice"`
	ExpiresAt     interface{}            `json:"expires_at,omitempty"`
	ClientSecret  interface{}            `json:"client_secret,omitempty"`
	OpenAI        map[string]interface{} `json:"openai,omitempty"`
	Configuration map[string]interface{} `json:"configuration,omitempty"`
}

func (a *API) createRealtimeClientSecretWithOpenAI(ctx context.Context, req RealtimeClientSecretRequest) (RealtimeClientSecretResult, error) {
	if strings.TrimSpace(a.cfg.OpenAIAPIKey) == "" {
		return RealtimeClientSecretResult{}, fmt.Errorf("OpenAI API key is not configured")
	}

	model := firstNonEmptyString(req.Model, a.cfg.OpenAIRealtimeModel, "gpt-realtime")
	voice := firstNonEmptyString(req.Voice, a.cfg.OpenAIRealtimeVoice, "marin")
	instructions := firstNonEmptyString(req.Instructions, defaultRealtimeInstructions())
	session := map[string]interface{}{
		"type":         "realtime",
		"model":        model,
		"instructions": instructions,
		"modalities":   []string{"audio", "text"},
		"audio": map[string]interface{}{
			"input": map[string]interface{}{
				"transcription": map[string]interface{}{
					"model": firstNonEmptyString(a.cfg.OpenAIRealtimeTranscriptionModel, a.cfg.OpenAISTTModel, "gpt-4o-transcribe"),
				},
				"turn_detection": map[string]interface{}{
					"type": firstNonEmptyString(a.cfg.OpenAIRealtimeTurnDetection, "semantic_vad"),
				},
			},
			"output": map[string]interface{}{
				"voice": voice,
			},
		},
	}
	if len(req.Metadata) > 0 {
		session["metadata"] = req.Metadata
	}

	payload, err := json.Marshal(map[string]interface{}{
		"session": session,
	})
	if err != nil {
		return RealtimeClientSecretResult{}, err
	}

	url := strings.TrimRight(firstNonEmptyString(a.cfg.OpenAIRealtimeBaseURL, a.cfg.OpenAIBaseURL, "https://api.openai.com"), "/") + "/v1/realtime/client_secrets"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return RealtimeClientSecretResult{}, err
	}
	httpReq.Header.Set("Authorization", "Bearer "+strings.TrimSpace(a.cfg.OpenAIAPIKey))
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := voiceHTTPClient().Do(httpReq)
	if err != nil {
		return RealtimeClientSecretResult{}, err
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return RealtimeClientSecretResult{}, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return RealtimeClientSecretResult{}, fmt.Errorf("OpenAI realtime client secret failed with status %d: %s", resp.StatusCode, compactErrorBody(data))
	}

	var decoded map[string]interface{}
	if err := json.Unmarshal(data, &decoded); err != nil {
		return RealtimeClientSecretResult{}, err
	}

	result := RealtimeClientSecretResult{
		Provider: "openai",
		Model:    model,
		Voice:    voice,
		OpenAI:   decoded,
		Configuration: map[string]interface{}{
			"base_url": strings.TrimRight(firstNonEmptyString(a.cfg.OpenAIRealtimeBaseURL, a.cfg.OpenAIBaseURL, "https://api.openai.com"), "/"),
		},
	}
	if clientSecret, ok := decoded["client_secret"]; ok {
		result.ClientSecret = clientSecret
	} else if value, ok := decoded["value"]; ok {
		result.ClientSecret = map[string]interface{}{
			"value":      value,
			"expires_at": decoded["expires_at"],
		}
	}
	if expiresAt, ok := decoded["expires_at"]; ok {
		result.ExpiresAt = expiresAt
	}
	return result, nil
}

func defaultRealtimeInstructions() string {
	return strings.TrimSpace(`You are Crow, a macOS-native voice-first assistant.
Keep voice responses concise and conversational.
Do not directly run tools, mutate files, browse, send emails, or approve actions.
When the user asks for execution, summarize the intended task so Crow can route it through local executors and approvals.`)
}
