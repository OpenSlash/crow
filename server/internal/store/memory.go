package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
)

type MemoryStore struct {
	mu           sync.Mutex
	cfg          Config
	devices      map[string]DeviceActivation
	deviceTokens map[string]string
	tokenDevices map[string]DeviceActivation
	entitlements map[string]Entitlement
	usageDaily   map[string]UsageDaily
}

func NewMemory(cfg Config) *MemoryStore {
	return &MemoryStore{
		cfg:          cfg,
		devices:      make(map[string]DeviceActivation),
		deviceTokens: make(map[string]string),
		tokenDevices: make(map[string]DeviceActivation),
		entitlements: make(map[string]Entitlement),
		usageDaily:   make(map[string]UsageDaily),
	}
}

func (s *MemoryStore) ActivateDevice(ctx context.Context, activation DeviceActivation) (DeviceActivation, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if activation.UserID == "" {
		activation.UserID = "dev_user"
	}
	if activation.Plan == "" {
		activation.Plan = s.cfg.DefaultPlan
	}
	if activation.ExpiresAt.IsZero() {
		activation.ExpiresAt = time.Now().UTC().Add(30 * 24 * time.Hour)
	}

	s.devices[activation.DeviceID] = activation
	if _, ok := s.entitlements[activation.UserID]; !ok {
		s.entitlements[activation.UserID] = DefaultEntitlement(activation.UserID, s.cfg)
	}

	token := "dev_" + randomToken(24)
	s.deviceTokens[activation.DeviceID] = token
	s.tokenDevices[token] = activation
	return activation, token, nil
}

func (s *MemoryStore) AuthenticateDeviceToken(ctx context.Context, token string) (DeviceActivation, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	activation, ok := s.tokenDevices[token]
	if !ok {
		return DeviceActivation{}, false, nil
	}
	if !activation.ExpiresAt.IsZero() && time.Now().UTC().After(activation.ExpiresAt) {
		return DeviceActivation{}, false, nil
	}
	return activation, true, nil
}

func (s *MemoryStore) GetEntitlement(ctx context.Context, userID string) (Entitlement, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if userID == "" {
		userID = "dev_user"
	}
	entitlement, ok := s.entitlements[userID]
	if !ok {
		entitlement = DefaultEntitlement(userID, s.cfg)
		s.entitlements[userID] = entitlement
	}
	return entitlement, nil
}

func (s *MemoryStore) RecordUsage(ctx context.Context, events []UsageEvent) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now().UTC()
	for index := range events {
		event := events[index]
		if event.UserID == "" {
			event.UserID = "dev_user"
		}
		if event.CreatedAt.IsZero() {
			event.CreatedAt = now
		}
		day := event.CreatedAt.Format("2006-01-02")
		key := event.UserID + ":" + day
		usage := s.usageDaily[key]
		usage.UserID = event.UserID
		usage.Day = day
		usage.Events++
		usage.UpdatedAt = now
		switch event.Unit {
		case "second", "seconds", "stt_second", "stt_seconds":
			usage.STTSeconds += event.Quantity
		case "char", "chars", "tts_char", "tts_chars":
			usage.TTSChars += event.Quantity
		case "token", "tokens", "agent_token", "agent_tokens":
			usage.AgentTokens += event.Quantity
		}
		s.usageDaily[key] = usage
	}
	return len(events), nil
}

func randomToken(bytes int) string {
	buffer := make([]byte, bytes)
	if _, err := rand.Read(buffer); err != nil {
		return time.Now().UTC().Format("20060102150405")
	}
	return hex.EncodeToString(buffer)
}
