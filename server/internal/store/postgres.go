package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type PostgresStore struct {
	cfg  Config
	pool *pgxpool.Pool
}

func NewPostgres(cfg Config) (*PostgresStore, error) {
	if strings.TrimSpace(cfg.DatabaseURL) == "" {
		return nil, fmt.Errorf("database URL is required for postgres store")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return nil, err
	}
	store := &PostgresStore{cfg: cfg, pool: pool}
	if err := store.migrate(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return store, nil
}

func (s *PostgresStore) ActivateDevice(ctx context.Context, activation DeviceActivation) (DeviceActivation, string, error) {
	if activation.UserID == "" {
		activation.UserID = "dev_user"
	}
	if activation.Plan == "" {
		activation.Plan = s.cfg.DefaultPlan
	}
	if activation.ExpiresAt.IsZero() {
		activation.ExpiresAt = time.Now().UTC().Add(30 * 24 * time.Hour)
	}

	token := "dev_" + pgRandomToken(24)
	_, err := s.pool.Exec(ctx, `
		insert into crow_devices (
			device_id, user_id, device_token, device_name, platform, app_version, plan, expires_at, updated_at
		)
		values ($1, $2, $3, $4, $5, $6, $7, $8, now())
		on conflict (device_id) do update set
			user_id = excluded.user_id,
			device_token = excluded.device_token,
			device_name = excluded.device_name,
			platform = excluded.platform,
			app_version = excluded.app_version,
			plan = excluded.plan,
			expires_at = excluded.expires_at,
			updated_at = now()
	`, activation.DeviceID, activation.UserID, token, activation.DeviceName, activation.Platform, activation.AppVersion, activation.Plan, activation.ExpiresAt)
	if err != nil {
		return DeviceActivation{}, "", err
	}

	entitlement := DefaultEntitlement(activation.UserID, s.cfg)
	if err := s.upsertEntitlement(ctx, entitlement); err != nil {
		return DeviceActivation{}, "", err
	}
	return activation, token, nil
}

func (s *PostgresStore) GetEntitlement(ctx context.Context, userID string) (Entitlement, error) {
	if userID == "" {
		userID = "dev_user"
	}

	var entitlement Entitlement
	var featuresJSON []byte
	var limitsJSON []byte
	err := s.pool.QueryRow(ctx, `
		select user_id, plan, features, limits
		from crow_entitlements
		where user_id = $1
	`, userID).Scan(&entitlement.UserID, &entitlement.Plan, &featuresJSON, &limitsJSON)
	if err == nil {
		if err := json.Unmarshal(featuresJSON, &entitlement.Features); err != nil {
			return Entitlement{}, err
		}
		if err := json.Unmarshal(limitsJSON, &entitlement.Limits); err != nil {
			return Entitlement{}, err
		}
		return entitlement, nil
	}

	entitlement = DefaultEntitlement(userID, s.cfg)
	if err := s.upsertEntitlement(ctx, entitlement); err != nil {
		return Entitlement{}, err
	}
	return entitlement, nil
}

func (s *PostgresStore) AuthenticateDeviceToken(ctx context.Context, token string) (DeviceActivation, bool, error) {
	var activation DeviceActivation
	err := s.pool.QueryRow(ctx, `
		select device_id, user_id, device_name, platform, app_version, plan, expires_at
		from crow_devices
		where device_token = $1 and expires_at > now()
	`, token).Scan(
		&activation.DeviceID,
		&activation.UserID,
		&activation.DeviceName,
		&activation.Platform,
		&activation.AppVersion,
		&activation.Plan,
		&activation.ExpiresAt,
	)
	if err != nil {
		if strings.Contains(err.Error(), "no rows") {
			return DeviceActivation{}, false, nil
		}
		return DeviceActivation{}, false, err
	}
	return activation, true, nil
}

func (s *PostgresStore) RecordUsage(ctx context.Context, events []UsageEvent) (int, error) {
	if len(events) == 0 {
		return 0, nil
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)

	now := time.Now().UTC()
	for index := range events {
		event := events[index]
		if event.UserID == "" {
			event.UserID = "dev_user"
		}
		if event.CreatedAt.IsZero() {
			event.CreatedAt = now
		}
		if event.EventID == "" {
			event.EventID = "evt_" + pgRandomToken(12)
		}
		metadata, err := json.Marshal(event.Metadata)
		if err != nil {
			return 0, err
		}
		if _, err := tx.Exec(ctx, `
			insert into crow_usage_events (
				event_id, user_id, device_id, event, quantity, unit, metadata, created_at
			)
			values ($1, $2, $3, $4, $5, $6, $7, $8)
			on conflict (event_id) do nothing
		`, event.EventID, event.UserID, event.DeviceID, event.Event, event.Quantity, event.Unit, metadata, event.CreatedAt); err != nil {
			return 0, err
		}

		sttSeconds, ttsChars, agentTokens := usageColumns(event)
		day := event.CreatedAt.Format("2006-01-02")
		if _, err := tx.Exec(ctx, `
			insert into crow_usage_daily (
				user_id, day, stt_seconds, tts_chars, agent_tokens, events, updated_at
			)
			values ($1, $2, $3, $4, $5, 1, now())
			on conflict (user_id, day) do update set
				stt_seconds = crow_usage_daily.stt_seconds + excluded.stt_seconds,
				tts_chars = crow_usage_daily.tts_chars + excluded.tts_chars,
				agent_tokens = crow_usage_daily.agent_tokens + excluded.agent_tokens,
				events = crow_usage_daily.events + 1,
				updated_at = now()
		`, event.UserID, day, sttSeconds, ttsChars, agentTokens); err != nil {
			return 0, err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return len(events), nil
}

func (s *PostgresStore) upsertEntitlement(ctx context.Context, entitlement Entitlement) error {
	features, err := json.Marshal(entitlement.Features)
	if err != nil {
		return err
	}
	limits, err := json.Marshal(entitlement.Limits)
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `
		insert into crow_entitlements (user_id, plan, features, limits, updated_at)
		values ($1, $2, $3, $4, now())
		on conflict (user_id) do update set
			plan = excluded.plan,
			features = excluded.features,
			limits = excluded.limits,
			updated_at = now()
	`, entitlement.UserID, entitlement.Plan, features, limits)
	return err
}

func (s *PostgresStore) migrate(ctx context.Context) error {
	statements := []string{
		`create table if not exists crow_devices (
			device_id text primary key,
			user_id text not null,
			device_token text not null,
			device_name text not null default '',
			platform text not null default '',
			app_version text not null default '',
			plan text not null default 'free',
			expires_at timestamptz not null,
			created_at timestamptz not null default now(),
			updated_at timestamptz not null default now()
		)`,
		`create table if not exists crow_entitlements (
			user_id text primary key,
			plan text not null,
			features jsonb not null,
			limits jsonb not null,
			created_at timestamptz not null default now(),
			updated_at timestamptz not null default now()
		)`,
		`create table if not exists crow_usage_events (
			event_id text primary key,
			user_id text not null,
			device_id text not null default '',
			event text not null,
			quantity bigint not null default 0,
			unit text not null default '',
			metadata jsonb not null default '{}',
			created_at timestamptz not null default now()
		)`,
		`create table if not exists crow_usage_daily (
			user_id text not null,
			day date not null,
			stt_seconds bigint not null default 0,
			tts_chars bigint not null default 0,
			agent_tokens bigint not null default 0,
			events bigint not null default 0,
			updated_at timestamptz not null default now(),
			primary key (user_id, day)
		)`,
		`create unique index if not exists crow_devices_device_token_idx
			on crow_devices (device_token)`,
	}

	for _, statement := range statements {
		if _, err := s.pool.Exec(ctx, statement); err != nil {
			return err
		}
	}
	return nil
}

func usageColumns(event UsageEvent) (sttSeconds int64, ttsChars int64, agentTokens int64) {
	switch event.Unit {
	case "second", "seconds", "stt_second", "stt_seconds":
		sttSeconds = event.Quantity
	case "char", "chars", "tts_char", "tts_chars":
		ttsChars = event.Quantity
	case "token", "tokens", "agent_token", "agent_tokens":
		agentTokens = event.Quantity
	}
	return sttSeconds, ttsChars, agentTokens
}

func pgRandomToken(bytes int) string {
	buffer := make([]byte, bytes)
	if _, err := rand.Read(buffer); err != nil {
		return time.Now().UTC().Format("20060102150405")
	}
	return hex.EncodeToString(buffer)
}
