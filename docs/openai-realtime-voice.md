# OpenAI Realtime Advanced Voice Plan

Crow V1 should not use OpenAI Realtime as the default voice path. The product default is STT + Agent + TTS through Crow Cloud. Realtime is reserved as a later advanced or paid low-latency conversation mode.

## Decision

```text
Default voice provider: Crow Cloud STT + TTS
Advanced voice provider: OpenAI Realtime
Fallback voice provider: macOS system speech
```

Realtime is only responsible for low-latency voice input/output when explicitly enabled. Crow remains responsible for task orchestration, Codex delegation, approvals, and history.

## Provider Selection

Default V1 path:

```bash
CROW_VOICE_PROVIDER='system'
CROW_STT_PROVIDER='cloud'
CROW_TTS_PROVIDER='cloud'
CROW_CLOUD_REALTIME_ENABLED='false'
```

Advanced Realtime path:

```bash
CROW_VOICE_PROVIDER='openai_realtime'
CROW_CLOUD_REALTIME_ENABLED='true'
CROW_OPENAI_REALTIME_MODEL='gpt-realtime'
CROW_OPENAI_REALTIME_TRANSCRIPTION_MODEL='gpt-4o-mini-transcribe'
CROW_OPENAI_REALTIME_VOICE='marin'
CROW_OPENAI_REALTIME_TURN_DETECTION='semantic_vad'
CROW_OPENAI_REALTIME_BASE_URL='https://api.openai.com'
```

Fallback:

```bash
CROW_VOICE_PROVIDER='system'
```

If `openai_realtime` is selected but the control plane or provider is unavailable, Crow must fall back to system speech and show a readable configuration hint.

The production path should not put the OpenAI API key in the macOS client. The macOS app should request an ephemeral Realtime secret from Crow Cloud:

```text
POST /v1/realtime/client-secret
```

Crow Cloud calls OpenAI `POST /v1/realtime/client_secrets` with the real API key and returns the short-lived client secret to the app.

## Architecture

```text
Notch wake
-> AVAudioEngine captures microphone audio
-> VoiceProviderSession
   -> Crow Cloud STT + TTS default
   -> OpenAIRealtimeVoiceSession
   -> SystemVoiceSession fallback
-> transcript events
-> Crow CreateTask(mode=agent)
-> Codex executor
-> task events
-> voice.output.segment
-> OpenAI Realtime response audio playback
   -> macOS system speech fallback
-> notch speaking animation
```

## Phase 1 Scope

- Keep Realtime disabled by default.
- Keep provider settings available for explicit advanced-mode testing.
- Keep the current macOS `SFSpeechRecognizer` and `AVSpeechSynthesizer` as fallback.
- Add OpenAI Realtime configuration validation.
- Add a provider abstraction so the notch does not depend directly on system speech.
- Add the server-side Realtime control plane endpoint that mints ephemeral client secrets.

Current implementation status:

- `CROW_VOICE_PROVIDER` is supported, but `.env` and `.env.example` default to the STT + TTS path.
- `openai_realtime` uses Crow Cloud ephemeral client secrets first and falls back to system speech when Realtime is unavailable.
- The native client has an OpenAI Realtime WebSocket session skeleton.
- The native client can convert microphone audio to 24kHz mono PCM16 and send `input_audio_buffer.append` events.
- The native client parses transcription delta/completed events when the provider returns them.
- The native client can decode Realtime response audio deltas and play PCM16 through a local output queue.
- Task `voice.output.segment` now uses OpenAI Realtime output when `CROW_VOICE_PROVIDER=openai_realtime` is configured.
- If Realtime output fails, Crow falls back to macOS `AVSpeechSynthesizer`.
- Crow Cloud exposes `/v1/realtime/client-secret` for the future production Realtime path.
- The macOS Realtime input/output path now requests Crow Cloud ephemeral client secrets first. A local `CROW_OPENAI_API_KEY` is only a development fallback when the control plane is unavailable.

## Phase 2 Scope

- Implement OpenAI Realtime WebSocket session in the daemon or native client.
- Stream microphone PCM frames to Realtime.
- Receive transcript deltas and response audio deltas.
- Play response audio through an output queue.
- Preserve interruption when the user starts speaking again.
- Route Crow/Codex final assistant output through Realtime audio, while keeping tool execution and approvals inside Crow.

## Phase 3 Scope

- Let Realtime classify direct conversation vs task execution.
- Keep tool execution behind Crow tasks and approvals.
- Add voice selector UI.
- Add fallback health checks.

## Non-Goals For First Realtime Phase

- Do not let Realtime directly run tools.
- Do not bypass Crow approvals.
- Do not remove system speech fallback.
- Do not support Gemini Live in the first provider.
