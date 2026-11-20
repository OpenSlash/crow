package main

import (
	"context"
	"os"
	"testing"

	"connectrpc.com/connect"
	crowv1 "github.com/crow/crow/apps/daemon/gen/crow/v1"
)

func TestSaveSettingsKeepsAndHidesAPIKey(t *testing.T) {
	for _, key := range []string{"CROW_LLM_API_KEY", "CROW_LLM_PROVIDER", "CROW_LLM_MODEL", "CROW_LLM_BASE_URL", "CROW_AGENT_MODE", "CROW_TTS_STREAMING"} {
		t.Setenv(key, "") // restored after the test
	}
	s := &server{settings: &crowv1.Settings{}}
	ctx := context.Background()

	resp, err := s.SaveSettings(ctx, connect.NewRequest(&crowv1.SaveSettingsRequest{
		Settings: &crowv1.Settings{LlmProvider: "deepseek", LlmApiKey: "sk-1"},
	}))
	if err != nil {
		t.Fatal(err)
	}
	if resp.Msg.GetLlmApiKey() != "" || !resp.Msg.GetLlmApiKeySet() {
		t.Fatalf("response leaked key or missing flag: %+v", resp.Msg)
	}
	if os.Getenv("CROW_LLM_API_KEY") != "sk-1" || os.Getenv("CROW_LLM_PROVIDER") != "deepseek" {
		t.Fatal("settings not applied to env")
	}

	// Saving without a key keeps the stored one.
	if _, err := s.SaveSettings(ctx, connect.NewRequest(&crowv1.SaveSettingsRequest{
		Settings: &crowv1.Settings{LlmProvider: "deepseek", LlmModel: "deepseek-chat"},
	})); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("CROW_LLM_API_KEY") != "sk-1" {
		t.Fatal("empty key cleared the stored key")
	}

	// Switching provider without a key must not reuse the previous provider's key.
	if _, err := s.SaveSettings(ctx, connect.NewRequest(&crowv1.SaveSettingsRequest{
		Settings: &crowv1.Settings{LlmProvider: "anthropic"},
	})); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("CROW_LLM_API_KEY") != "" {
		t.Fatal("previous provider key leaked to new provider")
	}
	if _, err := s.SaveSettings(ctx, connect.NewRequest(&crowv1.SaveSettingsRequest{
		Settings: &crowv1.Settings{LlmProvider: "deepseek", LlmModel: "deepseek-chat", LlmApiKey: "sk-1"},
	})); err != nil {
		t.Fatal(err)
	}

	got, _ := s.GetSettings(ctx, connect.NewRequest(&crowv1.GetSettingsRequest{}))
	if got.Msg.GetLlmApiKey() != "" || !got.Msg.GetLlmApiKeySet() || got.Msg.GetLlmModel() != "deepseek-chat" {
		t.Fatalf("GetSettings = %+v", got.Msg)
	}
}
