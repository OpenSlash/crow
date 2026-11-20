package store

import (
	"context"
	"time"
)

type DeviceActivation struct {
	DeviceID   string
	DeviceName string
	Platform   string
	AppVersion string
	UserID     string
	Plan       string
	ExpiresAt  time.Time
}

type Entitlement struct {
	UserID   string
	Plan     string
	Features FeatureSet
	Limits   LimitSet
}

type FeatureSet struct {
	VoiceSTT             bool
	VoiceTTS             bool
	ExecutorDelegation   bool
	ApprovalInIsland     bool
	HistorySync          bool
	RealtimeConversation bool
}

type LimitSet struct {
	STTMinutesMonth int64
	TTSCharsMonth   int64
	Devices         int64
}

type UsageEvent struct {
	EventID   string
	Event     string
	UserID    string
	DeviceID  string
	Quantity  int64
	Unit      string
	Metadata  map[string]interface{}
	CreatedAt time.Time
}

type UsageDaily struct {
	UserID      string
	Day         string
	STTSeconds  int64
	TTSChars    int64
	AgentTokens int64
	Events      int64
	UpdatedAt   time.Time
}

type Store interface {
	ActivateDevice(ctx context.Context, activation DeviceActivation) (DeviceActivation, string, error)
	AuthenticateDeviceToken(ctx context.Context, token string) (DeviceActivation, bool, error)
	GetEntitlement(ctx context.Context, userID string) (Entitlement, error)
	RecordUsage(ctx context.Context, events []UsageEvent) (int, error)
}

type Config struct {
	DefaultPlan     string
	VoiceEnabled    bool
	RealtimeEnabled bool
	DatabaseURL     string
}

func DefaultEntitlement(userID string, cfg Config) Entitlement {
	return Entitlement{
		UserID: userID,
		Plan:   cfg.DefaultPlan,
		Features: FeatureSet{
			VoiceSTT:             cfg.VoiceEnabled,
			VoiceTTS:             cfg.VoiceEnabled,
			ExecutorDelegation:   true,
			ApprovalInIsland:     true,
			HistorySync:          false,
			RealtimeConversation: cfg.RealtimeEnabled,
		},
		Limits: LimitSet{
			STTMinutesMonth: 600,
			TTSCharsMonth:   500000,
			Devices:         3,
		},
	}
}
