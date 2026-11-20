package server

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"strings"
	"time"

	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/app/server"
	"github.com/cloudwego/hertz/pkg/common/utils"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
	"github.com/crow/crow/server/internal/config"
	"github.com/crow/crow/server/internal/store"
)

type API struct {
	cfg   config.Config
	store store.Store
}

type authContextKey string

const authContextKeyCurrent authContextKey = "current_auth"

type AuthContext struct {
	UserID   string
	DeviceID string
}

type DeviceActivateRequest struct {
	DeviceID   string `json:"device_id"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
	AppVersion string `json:"app_version"`
}

type UsageEvent struct {
	EventID  string                 `json:"event_id"`
	Event    string                 `json:"event"`
	DeviceID string                 `json:"device_id"`
	Quantity int64                  `json:"quantity"`
	Unit     string                 `json:"unit"`
	Metadata map[string]interface{} `json:"metadata"`
}

func Run(cfg config.Config) error {
	st, err := store.New(cfg.StoreAdapter, store.Config{
		DefaultPlan:     cfg.DefaultPlan,
		VoiceEnabled:    cfg.VoiceEnabled,
		RealtimeEnabled: cfg.RealtimeEnabled,
		DatabaseURL:     cfg.DatabaseURL,
	})
	if err != nil {
		return err
	}
	h := server.Default(server.WithHostPorts(":" + cfg.Port))
	Register(h, cfg, st)
	h.Spin()
	return nil
}

func Register(h *server.Hertz, cfg config.Config, st store.Store) {
	api := &API{cfg: cfg, store: st}

	h.GET("/healthz", api.healthz)
	h.POST("/v1/devices/activate", api.activateDevice)
	h.GET("/v1/entitlements/me", api.requireAuth(api.entitlements))
	h.POST("/v1/voice/session", api.requireAuth(api.voiceSession))
	h.POST("/v1/voice/transcriptions", api.requireAuth(api.voiceTranscriptions))
	h.POST("/v1/voice/speech", api.requireAuth(api.voiceSpeech))
	h.POST("/v1/voice/speech-stream", api.requireAuth(api.voiceSpeechStream))
	h.POST("/v1/realtime/client-secret", api.requireAuth(api.realtimeClientSecret))
	h.POST("/v1/agent/respond", api.requireAuth(api.agentRespond))
	h.POST("/v1/agent/respond-stream", api.requireAuth(api.agentRespondStream))
	h.POST("/v1/usage/events", api.requireAuth(api.usageEvents))
	h.POST("/v1/stripe/webhook", api.stripeWebhook)
}

func (a *API) healthz(ctx context.Context, c *app.RequestContext) {
	c.JSON(consts.StatusOK, utils.H{
		"ok":          true,
		"service":     "crow-cloud",
		"environment": a.cfg.Environment,
		"time":        time.Now().UTC().Format(time.RFC3339),
	})
}

func (a *API) activateDevice(ctx context.Context, c *app.RequestContext) {
	var req DeviceActivateRequest
	if err := decodeJSON(c, &req); err != nil {
		writeError(c, consts.StatusBadRequest, "invalid_json", err.Error())
		return
	}

	deviceID := strings.TrimSpace(req.DeviceID)
	if deviceID == "" {
		deviceID = "device_" + time.Now().UTC().Format("20060102150405")
	}

	activation, token, err := a.store.ActivateDevice(ctx, store.DeviceActivation{
		DeviceID:   deviceID,
		DeviceName: strings.TrimSpace(req.DeviceName),
		Platform:   strings.TrimSpace(req.Platform),
		AppVersion: strings.TrimSpace(req.AppVersion),
		UserID:     "dev_user",
		Plan:       a.cfg.DefaultPlan,
		ExpiresAt:  time.Now().UTC().Add(30 * 24 * time.Hour),
	})
	if err != nil {
		writeError(c, consts.StatusInternalServerError, "store_error", err.Error())
		return
	}
	log.Printf("device activated device_id=%s user_id=%s platform=%s", activation.DeviceID, activation.UserID, activation.Platform)

	c.JSON(consts.StatusOK, utils.H{
		"device_id":    activation.DeviceID,
		"device_token": token,
		"user_id":      activation.UserID,
		"plan":         activation.Plan,
		"expires_at":   activation.ExpiresAt.Format(time.RFC3339),
	})
}

func (a *API) entitlements(ctx context.Context, c *app.RequestContext) {
	auth := currentAuth(ctx)
	entitlement, err := a.store.GetEntitlement(ctx, auth.UserID)
	if err != nil {
		writeError(c, consts.StatusInternalServerError, "store_error", err.Error())
		return
	}
	c.JSON(consts.StatusOK, utils.H{
		"user_id": entitlement.UserID,
		"plan":    entitlement.Plan,
		"features": utils.H{
			"voice_stt":             entitlement.Features.VoiceSTT,
			"voice_tts":             entitlement.Features.VoiceTTS,
			"executor_delegation":   entitlement.Features.ExecutorDelegation,
			"approval_in_island":    entitlement.Features.ApprovalInIsland,
			"history_sync":          entitlement.Features.HistorySync,
			"realtime_conversation": entitlement.Features.RealtimeConversation,
		},
		"limits": utils.H{
			"stt_minutes_month": entitlement.Limits.STTMinutesMonth,
			"tts_chars_month":   entitlement.Limits.TTSCharsMonth,
			"devices":           entitlement.Limits.Devices,
		},
	})
}

func (a *API) voiceSession(ctx context.Context, c *app.RequestContext) {
	auth := currentAuth(ctx)
	entitlement, err := a.store.GetEntitlement(ctx, auth.UserID)
	if err != nil {
		writeError(c, consts.StatusInternalServerError, "store_error", err.Error())
		return
	}
	if !entitlement.Features.VoiceSTT || !entitlement.Features.VoiceTTS {
		writeError(c, consts.StatusPaymentRequired, "voice_disabled", "Voice entitlement is not enabled for this account")
		return
	}

	expiresAt := time.Now().UTC().Add(a.cfg.VoiceSessionTTL)
	c.JSON(consts.StatusOK, utils.H{
		"provider_mode": "stt_tts",
		"expires_at":    expiresAt.Format(time.RFC3339),
		"stt": utils.H{
			"provider": "openai",
			"model":    a.cfg.OpenAISTTModel,
			"base_url": a.cfg.OpenAIBaseURL,
		},
		"tts": utils.H{
			"provider": "openai",
			"model":    a.cfg.OpenAITTSModel,
			"voice":    a.cfg.OpenAITTSVoice,
			"base_url": a.cfg.OpenAIBaseURL,
		},
		"fallback": utils.H{
			"stt": "system",
			"tts": "system",
		},
	})
}

func (a *API) voiceTranscriptions(ctx context.Context, c *app.RequestContext) {
	auth := currentAuth(ctx)
	entitlement, err := a.store.GetEntitlement(ctx, auth.UserID)
	if err != nil {
		writeError(c, consts.StatusInternalServerError, "store_error", err.Error())
		return
	}
	if !entitlement.Features.VoiceSTT {
		writeError(c, consts.StatusPaymentRequired, "voice_stt_disabled", "STT entitlement is not enabled for this account")
		return
	}

	fileHeader, err := c.FormFile("file")
	if err != nil {
		writeError(c, consts.StatusBadRequest, "missing_audio_file", "Multipart field file is required")
		return
	}
	file, err := fileHeader.Open()
	if err != nil {
		writeError(c, consts.StatusBadRequest, "invalid_audio_file", err.Error())
		return
	}
	defer file.Close()

	audio, err := io.ReadAll(io.LimitReader(file, 32<<20))
	if err != nil {
		writeError(c, consts.StatusBadRequest, "read_audio_failed", err.Error())
		return
	}
	if len(audio) == 0 {
		writeError(c, consts.StatusBadRequest, "empty_audio_file", "Audio file is empty")
		return
	}

	language := strings.TrimSpace(string(c.FormValue("language")))
	result, err := a.transcribeWithOpenAI(ctx, audio, fileHeader.Filename, fileHeader.Header.Get("Content-Type"), language)
	if err != nil {
		log.Printf("voice transcription failed user_id=%s device_id=%s error=%v", auth.UserID, auth.DeviceID, err)
		writeError(c, consts.StatusBadGateway, "stt_provider_error", err.Error())
		return
	}
	log.Printf("voice transcription completed user_id=%s device_id=%s bytes=%d", auth.UserID, auth.DeviceID, len(audio))

	_, _ = a.store.RecordUsage(ctx, []store.UsageEvent{{
		EventID:  "stt_" + time.Now().UTC().Format("20060102150405.000000000"),
		Event:    "voice.stt",
		UserID:   auth.UserID,
		DeviceID: auth.DeviceID,
		Quantity: estimateAudioSeconds(fileHeader.Size),
		Unit:     "stt_seconds",
		Metadata: map[string]interface{}{
			"provider": "openai",
			"model":    a.cfg.OpenAISTTModel,
			"bytes":    len(audio),
		},
		CreatedAt: time.Now().UTC(),
	}})

	c.JSON(consts.StatusOK, utils.H{
		"text":     result.Text,
		"provider": "openai",
		"model":    a.cfg.OpenAISTTModel,
	})
}

func (a *API) voiceSpeech(ctx context.Context, c *app.RequestContext) {
	auth := currentAuth(ctx)
	entitlement, err := a.store.GetEntitlement(ctx, auth.UserID)
	if err != nil {
		writeError(c, consts.StatusInternalServerError, "store_error", err.Error())
		return
	}
	if !entitlement.Features.VoiceTTS {
		writeError(c, consts.StatusPaymentRequired, "voice_tts_disabled", "TTS entitlement is not enabled for this account")
		return
	}

	var req struct {
		Text   string `json:"text"`
		Voice  string `json:"voice"`
		Format string `json:"format"`
	}
	if err := decodeJSON(c, &req); err != nil {
		writeError(c, consts.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if strings.TrimSpace(req.Text) == "" {
		writeError(c, consts.StatusBadRequest, "missing_text", "text is required")
		return
	}

	result, err := a.speakWithOpenAI(ctx, req.Text, strings.TrimSpace(req.Voice), strings.TrimSpace(req.Format))
	if err != nil {
		log.Printf("voice speech failed user_id=%s device_id=%s error=%v", auth.UserID, auth.DeviceID, err)
		writeError(c, consts.StatusBadGateway, "tts_provider_error", err.Error())
		return
	}
	log.Printf("voice speech completed user_id=%s device_id=%s chars=%d", auth.UserID, auth.DeviceID, len([]rune(req.Text)))

	_, _ = a.store.RecordUsage(ctx, []store.UsageEvent{{
		EventID:  "tts_" + time.Now().UTC().Format("20060102150405.000000000"),
		Event:    "voice.tts",
		UserID:   auth.UserID,
		DeviceID: auth.DeviceID,
		Quantity: int64(len([]rune(req.Text))),
		Unit:     "tts_chars",
		Metadata: map[string]interface{}{
			"provider": "openai",
			"model":    a.cfg.OpenAITTSModel,
			"voice":    firstNonEmptyString(req.Voice, a.cfg.OpenAITTSVoice),
		},
		CreatedAt: time.Now().UTC(),
	}})

	c.Data(consts.StatusOK, result.ContentType, result.Audio)
}

func (a *API) voiceSpeechStream(ctx context.Context, c *app.RequestContext) {
	auth := currentAuth(ctx)
	entitlement, err := a.store.GetEntitlement(ctx, auth.UserID)
	if err != nil {
		writeError(c, consts.StatusInternalServerError, "store_error", err.Error())
		return
	}
	if !entitlement.Features.VoiceTTS {
		writeError(c, consts.StatusPaymentRequired, "voice_tts_disabled", "TTS entitlement is not enabled for this account")
		return
	}

	var req struct {
		Text  string `json:"text"`
		Voice string `json:"voice"`
	}
	if err := decodeJSON(c, &req); err != nil {
		writeError(c, consts.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if strings.TrimSpace(req.Text) == "" {
		writeError(c, consts.StatusBadRequest, "missing_text", "text is required")
		return
	}

	reader, writer := io.Pipe()
	c.Response.Header.Set("Content-Type", "audio/pcm")
	c.Response.Header.Set("Cache-Control", "no-cache")
	c.Response.Header.Set("X-Crow-Audio-Format", "pcm16")
	c.Response.Header.Set("X-Crow-Sample-Rate", "24000")
	c.Response.Header.Set("X-Crow-Channels", "1")
	c.SetBodyStream(reader, -1)

	go func() {
		defer writer.Close()
		if err := a.streamSpeechWithOpenAI(ctx, req.Text, strings.TrimSpace(req.Voice), writer); err != nil {
			log.Printf("voice speech stream failed user_id=%s device_id=%s error=%v", auth.UserID, auth.DeviceID, err)
			_ = writer.CloseWithError(err)
			return
		}
		log.Printf("voice speech stream completed user_id=%s device_id=%s chars=%d", auth.UserID, auth.DeviceID, len([]rune(req.Text)))
		_, _ = a.store.RecordUsage(ctx, []store.UsageEvent{{
			EventID:  "tts_stream_" + time.Now().UTC().Format("20060102150405.000000000"),
			Event:    "voice.tts_stream",
			UserID:   auth.UserID,
			DeviceID: auth.DeviceID,
			Quantity: int64(len([]rune(req.Text))),
			Unit:     "tts_chars",
			Metadata: map[string]interface{}{
				"provider": "openai",
				"model":    a.cfg.OpenAITTSModel,
				"voice":    firstNonEmptyString(req.Voice, a.cfg.OpenAITTSVoice),
				"format":   "pcm",
			},
			CreatedAt: time.Now().UTC(),
		}})
	}()
}

func (a *API) realtimeClientSecret(ctx context.Context, c *app.RequestContext) {
	auth := currentAuth(ctx)
	entitlement, err := a.store.GetEntitlement(ctx, auth.UserID)
	if err != nil {
		writeError(c, consts.StatusInternalServerError, "store_error", err.Error())
		return
	}
	if !entitlement.Features.RealtimeConversation {
		writeError(c, consts.StatusPaymentRequired, "realtime_disabled", "Realtime conversation entitlement is not enabled for this account")
		return
	}

	var req RealtimeClientSecretRequest
	if len(c.Request.Body()) > 0 {
		if err := decodeJSON(c, &req); err != nil {
			writeError(c, consts.StatusBadRequest, "invalid_json", err.Error())
			return
		}
	}

	result, err := a.createRealtimeClientSecretWithOpenAI(ctx, req)
	if err != nil {
		log.Printf("realtime client secret failed user_id=%s device_id=%s error=%v", auth.UserID, auth.DeviceID, err)
		writeError(c, consts.StatusBadGateway, "realtime_provider_error", err.Error())
		return
	}

	_, _ = a.store.RecordUsage(ctx, []store.UsageEvent{{
		EventID:  "realtime_session_" + time.Now().UTC().Format("20060102150405.000000000"),
		Event:    "voice.realtime.client_secret",
		UserID:   auth.UserID,
		DeviceID: auth.DeviceID,
		Quantity: 1,
		Unit:     "session",
		Metadata: map[string]interface{}{
			"provider": result.Provider,
			"model":    result.Model,
			"voice":    result.Voice,
		},
		CreatedAt: time.Now().UTC(),
	}})
	log.Printf("realtime client secret created user_id=%s device_id=%s model=%s", auth.UserID, auth.DeviceID, result.Model)

	c.JSON(consts.StatusOK, result)
}

func (a *API) agentRespond(ctx context.Context, c *app.RequestContext) {
	auth := currentAuth(ctx)
	entitlement, err := a.store.GetEntitlement(ctx, auth.UserID)
	if err != nil {
		writeError(c, consts.StatusInternalServerError, "store_error", err.Error())
		return
	}
	if !entitlement.Features.ExecutorDelegation {
		writeError(c, consts.StatusPaymentRequired, "agent_disabled", "Agent entitlement is not enabled for this account")
		return
	}

	var req AgentRespondRequest
	if err := decodeJSON(c, &req); err != nil {
		writeError(c, consts.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if strings.TrimSpace(req.Input) == "" && len(req.Messages) == 0 {
		writeError(c, consts.StatusBadRequest, "missing_input", "input or messages is required")
		return
	}
	req.Stream = false

	result, err := a.respondWithOpenAI(ctx, req)
	if err != nil {
		log.Printf("agent respond failed user_id=%s device_id=%s error=%v", auth.UserID, auth.DeviceID, err)
		writeError(c, consts.StatusBadGateway, "agent_provider_error", err.Error())
		return
	}

	_, _ = a.store.RecordUsage(ctx, []store.UsageEvent{{
		EventID:  "agent_" + time.Now().UTC().Format("20060102150405.000000000"),
		Event:    "agent.respond",
		UserID:   auth.UserID,
		DeviceID: auth.DeviceID,
		Quantity: agentUsageTokens(result.Usage),
		Unit:     "agent_tokens",
		Metadata: map[string]interface{}{
			"provider": "openai",
			"model":    result.Model,
		},
		CreatedAt: time.Now().UTC(),
	}})
	log.Printf("agent respond completed user_id=%s device_id=%s model=%s", auth.UserID, auth.DeviceID, result.Model)

	c.JSON(consts.StatusOK, result)
}

func (a *API) agentRespondStream(ctx context.Context, c *app.RequestContext) {
	auth := currentAuth(ctx)
	entitlement, err := a.store.GetEntitlement(ctx, auth.UserID)
	if err != nil {
		writeError(c, consts.StatusInternalServerError, "store_error", err.Error())
		return
	}
	if !entitlement.Features.ExecutorDelegation {
		writeError(c, consts.StatusPaymentRequired, "agent_disabled", "Agent entitlement is not enabled for this account")
		return
	}

	var req AgentRespondRequest
	if err := decodeJSON(c, &req); err != nil {
		writeError(c, consts.StatusBadRequest, "invalid_json", err.Error())
		return
	}
	if strings.TrimSpace(req.Input) == "" && len(req.Messages) == 0 {
		writeError(c, consts.StatusBadRequest, "missing_input", "input or messages is required")
		return
	}
	req.Stream = true

	reader, writer := io.Pipe()
	c.Response.Header.Set("Content-Type", "text/event-stream; charset=utf-8")
	c.Response.Header.Set("Cache-Control", "no-cache")
	c.Response.Header.Set("Connection", "keep-alive")
	c.SetBodyStream(reader, -1)

	go func() {
		defer writer.Close()
		writeSSE := func(event string, payload interface{}) error {
			data, err := json.Marshal(payload)
			if err != nil {
				return err
			}
			_, err = writer.Write([]byte("event: " + event + "\n" + "data: " + string(data) + "\n\n"))
			return err
		}

		done, err := a.streamRespondWithOpenAI(ctx, req, func(delta AgentStreamDelta) error {
			return writeSSE("delta", delta)
		})
		if err != nil {
			log.Printf("agent stream failed user_id=%s device_id=%s error=%v", auth.UserID, auth.DeviceID, err)
			_ = writeSSE("error", utils.H{
				"code":    "agent_provider_error",
				"message": err.Error(),
			})
			return
		}

		_, _ = a.store.RecordUsage(ctx, []store.UsageEvent{{
			EventID:  "agent_stream_" + time.Now().UTC().Format("20060102150405.000000000"),
			Event:    "agent.respond_stream",
			UserID:   auth.UserID,
			DeviceID: auth.DeviceID,
			Quantity: 0,
			Unit:     "agent_tokens",
			Metadata: map[string]interface{}{
				"provider": done.Provider,
				"model":    done.Model,
				"stream":   true,
			},
			CreatedAt: time.Now().UTC(),
		}})
		log.Printf("agent stream completed user_id=%s device_id=%s model=%s need_executor=%t", auth.UserID, auth.DeviceID, done.Model, done.NeedExecutor)
		_ = writeSSE("done", done)
	}()
}

func (a *API) usageEvents(ctx context.Context, c *app.RequestContext) {
	auth := currentAuth(ctx)
	var events []UsageEvent
	if err := decodeJSON(c, &events); err != nil {
		var single UsageEvent
		if err2 := decodeJSON(c, &single); err2 != nil {
			writeError(c, consts.StatusBadRequest, "invalid_json", err.Error())
			return
		}
		events = []UsageEvent{single}
	}

	usageEvents := make([]store.UsageEvent, 0, len(events))
	for _, event := range events {
		usageEvents = append(usageEvents, store.UsageEvent{
			EventID:   event.EventID,
			Event:     event.Event,
			UserID:    auth.UserID,
			DeviceID:  firstNonEmptyString(event.DeviceID, auth.DeviceID),
			Quantity:  event.Quantity,
			Unit:      event.Unit,
			Metadata:  event.Metadata,
			CreatedAt: time.Now().UTC(),
		})
	}

	accepted, err := a.store.RecordUsage(ctx, usageEvents)
	if err != nil {
		writeError(c, consts.StatusInternalServerError, "store_error", err.Error())
		return
	}

	c.JSON(consts.StatusAccepted, utils.H{
		"accepted": accepted,
	})
}

func (a *API) stripeWebhook(ctx context.Context, c *app.RequestContext) {
	if a.cfg.StripeWebhookKey == "" && a.cfg.Environment == "production" {
		writeError(c, consts.StatusServiceUnavailable, "stripe_not_configured", "Stripe webhook secret is not configured")
		return
	}

	c.JSON(consts.StatusOK, utils.H{
		"received": true,
	})
}

func (a *API) requireAuth(next app.HandlerFunc) app.HandlerFunc {
	return func(ctx context.Context, c *app.RequestContext) {
		if a.cfg.DevToken == "" && a.cfg.AllowAnonymousDev && a.cfg.Environment != "production" {
			next(withAuth(ctx, AuthContext{UserID: "dev_user"}), c)
			return
		}

		auth := string(c.GetHeader("Authorization"))
		token := strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
		if token == "" {
			writeError(c, consts.StatusUnauthorized, "unauthorized", "Missing or invalid bearer token")
			return
		}
		if a.cfg.DevToken != "" && token == a.cfg.DevToken {
			next(withAuth(ctx, AuthContext{UserID: "dev_user"}), c)
			return
		}

		activation, ok, err := a.store.AuthenticateDeviceToken(ctx, token)
		if err != nil {
			writeError(c, consts.StatusInternalServerError, "store_error", err.Error())
			return
		}
		if !ok {
			writeError(c, consts.StatusUnauthorized, "unauthorized", "Missing or invalid bearer token")
			return
		}
		next(withAuth(ctx, AuthContext{UserID: activation.UserID, DeviceID: activation.DeviceID}), c)
	}
}

func withAuth(ctx context.Context, auth AuthContext) context.Context {
	if auth.UserID == "" {
		auth.UserID = "dev_user"
	}
	return context.WithValue(ctx, authContextKeyCurrent, auth)
}

func currentAuth(ctx context.Context) AuthContext {
	auth, ok := ctx.Value(authContextKeyCurrent).(AuthContext)
	if !ok || auth.UserID == "" {
		return AuthContext{UserID: "dev_user"}
	}
	return auth
}

func decodeJSON(c *app.RequestContext, target interface{}) error {
	return json.Unmarshal(c.Request.Body(), target)
}

func writeError(c *app.RequestContext, status int, code string, message string) {
	c.JSON(status, utils.H{
		"error": utils.H{
			"code":    code,
			"message": message,
		},
	})
}

func estimateAudioSeconds(size int64) int64 {
	if size <= 0 {
		return 1
	}
	// Default client upload is 16 kHz mono PCM16 WAV, roughly 32 KB/s.
	seconds := size / 32000
	if size%32000 != 0 {
		seconds++
	}
	if seconds < 1 {
		return 1
	}
	return seconds
}

func agentUsageTokens(usage map[string]interface{}) int64 {
	if usage == nil {
		return 0
	}
	for _, key := range []string{"total_tokens", "totalTokens"} {
		switch value := usage[key].(type) {
		case float64:
			return int64(value)
		case int64:
			return value
		case int:
			return int64(value)
		}
	}
	return 0
}
