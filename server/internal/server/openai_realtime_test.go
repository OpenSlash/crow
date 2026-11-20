package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/crow/crow/server/internal/config"
)

func TestCreateRealtimeClientSecretWithOpenAI(t *testing.T) {
	var captured map[string]interface{}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Fatalf("method = %s, want POST", r.Method)
		}
		if r.URL.Path != "/v1/realtime/client_secrets" {
			t.Fatalf("path = %s, want /v1/realtime/client_secrets", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("authorization = %q", got)
		}
		if err := json.NewDecoder(r.Body).Decode(&captured); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"client_secret":{"value":"ek_test","expires_at":12345},"expires_at":12345}`))
	}))
	defer upstream.Close()

	api := &API{cfg: config.Config{
		OpenAIAPIKey:                     "test-key",
		OpenAIRealtimeBaseURL:            upstream.URL,
		OpenAIRealtimeModel:              "gpt-realtime",
		OpenAIRealtimeVoice:              "marin",
		OpenAIRealtimeTranscriptionModel: "gpt-4o-mini-transcribe",
		OpenAIRealtimeTurnDetection:      "semantic_vad",
	}}

	result, err := api.createRealtimeClientSecretWithOpenAI(context.Background(), RealtimeClientSecretRequest{
		Model:        "gpt-realtime",
		Voice:        "marin",
		Instructions: "test instructions",
		Metadata: map[string]interface{}{
			"device": "mac",
		},
	})
	if err != nil {
		t.Fatalf("createRealtimeClientSecretWithOpenAI returned error: %v", err)
	}
	if result.Provider != "openai" || result.Model != "gpt-realtime" || result.Voice != "marin" {
		t.Fatalf("unexpected result metadata: %+v", result)
	}
	secret, ok := result.ClientSecret.(map[string]interface{})
	if !ok || secret["value"] != "ek_test" {
		t.Fatalf("client secret = %#v, want ek_test object", result.ClientSecret)
	}

	session, ok := captured["session"].(map[string]interface{})
	if !ok {
		t.Fatalf("captured session missing: %#v", captured)
	}
	if session["model"] != "gpt-realtime" {
		t.Fatalf("session model = %#v", session["model"])
	}
	if session["instructions"] != "test instructions" {
		t.Fatalf("session instructions = %#v", session["instructions"])
	}
	if session["metadata"].(map[string]interface{})["device"] != "mac" {
		t.Fatalf("session metadata = %#v", session["metadata"])
	}
}
