package config

import (
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Port                             string
	Environment                      string
	DevToken                         string
	DefaultPlan                      string
	StoreAdapter                     string
	DatabaseURL                      string
	VoiceEnabled                     bool
	RealtimeEnabled                  bool
	OpenAIBaseURL                    string
	OpenAIAPIKey                     string
	OpenAIAgentModel                 string
	OpenAIRealtimeBaseURL            string
	OpenAIRealtimeModel              string
	OpenAIRealtimeVoice              string
	OpenAIRealtimeTranscriptionModel string
	OpenAIRealtimeTurnDetection      string
	OpenAISTTModel                   string
	OpenAITTSModel                   string
	OpenAITTSVoice                   string
	VoiceSessionTTL                  time.Duration
	StripeWebhookKey                 string
	AllowAnonymousDev                bool
}

func Load() Config {
	LoadDotEnv()

	return Config{
		Port:                             firstNonEmpty(os.Getenv("PORT"), "8080"),
		Environment:                      firstNonEmpty(os.Getenv("CROW_CLOUD_ENV"), "development"),
		DevToken:                         os.Getenv("CROW_CLOUD_DEV_TOKEN"),
		DefaultPlan:                      firstNonEmpty(os.Getenv("CROW_CLOUD_DEFAULT_PLAN"), "pro"),
		StoreAdapter:                     firstNonEmpty(os.Getenv("CROW_CLOUD_STORE"), "memory"),
		DatabaseURL:                      firstNonEmpty(os.Getenv("CROW_DATABASE_URL"), os.Getenv("DATABASE_URL")),
		VoiceEnabled:                     boolEnv("CROW_CLOUD_VOICE_ENABLED", true),
		RealtimeEnabled:                  boolEnv("CROW_CLOUD_REALTIME_ENABLED", false),
		OpenAIBaseURL:                    firstNonEmpty(os.Getenv("CROW_OPENAI_BASE_URL"), "https://api.openai.com"),
		OpenAIAPIKey:                     os.Getenv("CROW_OPENAI_API_KEY"),
		OpenAIAgentModel:                 firstNonEmpty(os.Getenv("CROW_OPENAI_AGENT_MODEL"), "gpt-4.1-mini"),
		OpenAIRealtimeBaseURL:            firstNonEmpty(os.Getenv("CROW_OPENAI_REALTIME_BASE_URL"), os.Getenv("CROW_OPENAI_BASE_URL"), "https://api.openai.com"),
		OpenAIRealtimeModel:              firstNonEmpty(os.Getenv("CROW_OPENAI_REALTIME_MODEL"), "gpt-realtime"),
		OpenAIRealtimeVoice:              firstNonEmpty(os.Getenv("CROW_OPENAI_REALTIME_VOICE"), "marin"),
		OpenAIRealtimeTranscriptionModel: firstNonEmpty(os.Getenv("CROW_OPENAI_REALTIME_TRANSCRIPTION_MODEL"), os.Getenv("CROW_OPENAI_STT_MODEL"), "gpt-4o-transcribe"),
		OpenAIRealtimeTurnDetection:      firstNonEmpty(os.Getenv("CROW_OPENAI_REALTIME_TURN_DETECTION"), "semantic_vad"),
		OpenAISTTModel:                   firstNonEmpty(os.Getenv("CROW_OPENAI_STT_MODEL"), "gpt-4o-transcribe"),
		OpenAITTSModel:                   firstNonEmpty(os.Getenv("CROW_OPENAI_TTS_MODEL"), "gpt-4o-mini-tts"),
		OpenAITTSVoice:                   firstNonEmpty(os.Getenv("CROW_OPENAI_TTS_VOICE"), "marin"),
		VoiceSessionTTL:                  durationEnv("CROW_CLOUD_VOICE_SESSION_TTL_SECONDS", 15*time.Minute),
		StripeWebhookKey:                 os.Getenv("STRIPE_WEBHOOK_SECRET"),
		AllowAnonymousDev:                boolEnv("CROW_CLOUD_ALLOW_ANON_DEV", true),
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func boolEnv(key string, fallback bool) bool {
	raw := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if raw == "" {
		return fallback
	}
	return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
}

func durationEnv(key string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}
	seconds, err := strconv.Atoi(raw)
	if err != nil || seconds <= 0 {
		return fallback
	}
	return time.Duration(seconds) * time.Second
}
