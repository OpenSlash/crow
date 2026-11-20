# Crow Cloud Backend

Crow Cloud is the subscription, entitlement, and voice-session control plane for the macOS app.

## Stack

```text
Go
CloudWeGo Hertz
Google Cloud Run
Secret Manager
Stripe webhooks
Firestore or Cloud SQL later
```

Hertz is used for the first public HTTP API. Kitex can be added later if Crow Cloud grows internal RPC services.

## First APIs

```text
GET  /healthz
POST /v1/devices/activate
GET  /v1/entitlements/me
POST /v1/voice/session
POST /v1/voice/transcriptions
POST /v1/voice/speech
POST /v1/realtime/client-secret
POST /v1/agent/respond
POST /v1/usage/events
POST /v1/stripe/webhook
```

`/v1/voice/session` returns the STT + TTS configuration for the client.
`/v1/voice/transcriptions` and `/v1/voice/speech` proxy OpenAI audio calls from the backend so client apps never need the OpenAI API key.
`/v1/realtime/client-secret` creates a short-lived OpenAI Realtime client secret. The macOS app uses that ephemeral token for direct Realtime transport, while Crow Cloud keeps the real OpenAI API key server-side.
`/v1/agent/respond` is the first server-side Crow Agent model endpoint. It returns an assistant response and may include an executor hint for local delegation.

## Auth

The client first activates a device:

```bash
curl -sS \
  -H 'Content-Type: application/json' \
  -d '{"device_id":"local-mac","device_name":"MacBook","platform":"macos","app_version":"dev"}' \
  http://127.0.0.1:18089/v1/devices/activate
```

The response contains `device_token`. Protected APIs accept it as a bearer token:

```bash
curl -sS \
  -H "Authorization: Bearer ${CROW_DEVICE_TOKEN}" \
  http://127.0.0.1:18089/v1/entitlements/me
```

Development mode still supports anonymous protected calls when:

```env
CROW_CLOUD_ALLOW_ANON_DEV=true
CROW_CLOUD_ENV=development
CROW_CLOUD_DEV_TOKEN=
```

Production should disable anonymous dev access and use real device tokens or an explicit dev/admin token.

## Local Run

```bash
cd server
go run ./cmd/crow-cloud
```

## Deploy

```bash
gcloud run deploy crow-api \
  --source ./server \
  --region us-central1 \
  --allow-unauthenticated \
  --set-env-vars CROW_CLOUD_ENV=production
```

Production should set secrets through Secret Manager:

```text
CROW_CLOUD_DEV_TOKEN
CROW_CLOUD_STORE
STRIPE_WEBHOOK_SECRET
CROW_OPENAI_API_KEY
CROW_OPENAI_BASE_URL
CROW_OPENAI_RESOLVE_IP
CROW_OPENAI_DISABLE_PROXY
CROW_OPENAI_AGENT_MODEL
CROW_CLOUD_REALTIME_ENABLED
CROW_OPENAI_REALTIME_BASE_URL
CROW_OPENAI_REALTIME_MODEL
CROW_OPENAI_REALTIME_TRANSCRIPTION_MODEL
CROW_OPENAI_REALTIME_VOICE
CROW_OPENAI_REALTIME_TURN_DETECTION
CROW_OPENAI_STT_MODEL
CROW_OPENAI_TTS_MODEL
CROW_OPENAI_TTS_VOICE
```

`CROW_OPENAI_RESOLVE_IP` and `CROW_OPENAI_DISABLE_PROXY` are local development escape hatches for bad DNS/proxy routing. Leave them empty or false in Cloud Run and normal production environments.

Storage is selected with:

```text
CROW_CLOUD_STORE=memory
CROW_CLOUD_STORE=firestore
CROW_CLOUD_STORE=postgres
```

The first implementation uses `memory`; Firestore and Neon Postgres should be added as store adapters behind `internal/store.Store`.
`postgres` is implemented and can be used with Neon by setting `CROW_DATABASE_URL` or `DATABASE_URL`.

## Voice Strategy

V1:

```text
Client records audio
-> Crow Cloud /v1/voice/transcriptions
-> OpenAI STT
-> Crow Agent / Executor
-> Crow Cloud /v1/voice/speech
-> OpenAI TTS
```

Backend controls:

```text
subscription
entitlement
provider config
usage events
device activation
```

Advanced:

```text
short-lived model credentials
server-side voice quota checks
Realtime as paid advanced voice mode
```

Realtime control plane:

```text
macOS app
-> Crow Cloud /v1/realtime/client-secret
-> OpenAI /v1/realtime/client_secrets
-> ephemeral client secret
-> macOS app connects directly to OpenAI Realtime
```

The Realtime endpoint is entitlement-gated through `realtime_conversation` and is not part of the default V1 STT + TTS path. Only enable it when explicitly testing the advanced Realtime path:

```env
CROW_CLOUD_REALTIME_ENABLED=true
```

In production this should be tied to subscription state instead of being enabled globally. Default development and production STT + TTS configs should leave it disabled.

## Voice Smoke Test

Start the backend locally:

```bash
cd server
CROW_OPENAI_API_KEY='sk-...' \
CROW_OPENAI_AGENT_MODEL='gpt-4.1-mini' \
CROW_OPENAI_STT_MODEL='gpt-4o-mini-transcribe' \
CROW_OPENAI_TTS_MODEL='gpt-4o-mini-tts' \
CROW_OPENAI_TTS_VOICE='marin' \
go run ./cmd/crow-cloud
```

Test STT with a WAV/MP3/M4A file:

```bash
curl -sS \
  -H "Authorization: Bearer ${CROW_DEVICE_TOKEN}" \
  -F language=zh \
  -F file=@/path/to/audio.wav \
  http://127.0.0.1:18089/v1/voice/transcriptions
```

Test TTS:

```bash
curl -sS \
  -H "Authorization: Bearer ${CROW_DEVICE_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"text":"你好，我是 Crow。","voice":"marin","format":"mp3"}' \
  http://127.0.0.1:18089/v1/voice/speech \
  --output /tmp/crow-tts.mp3
```

Test Agent response:

```bash
curl -sS \
  -H "Authorization: Bearer ${CROW_DEVICE_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"input":"用一句话说明 Crow 是什么","mode":"voice"}' \
  http://127.0.0.1:18089/v1/agent/respond
```

Optional advanced Realtime client secret test:

```bash
curl -sS \
  -H "Authorization: Bearer ${CROW_DEVICE_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"voice":"marin"}' \
  http://127.0.0.1:18089/v1/realtime/client-secret
```
