# OpenAI STT + TTS Voice Plan

Crow V1 uses STT + Agent + TTS as the default voice path. Realtime remains an advanced continuous conversation mode.

## Default Path

```text
Notch wake
-> AVAudioEngine captures microphone audio
-> Crow Cloud transcription endpoint
-> OpenAI transcription
-> Crow Agent task
-> Executor / Codex
-> Crow final response
-> Crow Cloud speech endpoint
-> OpenAI speech
-> macOS system speech fallback
```

## Configuration

```env
CROW_STT_PROVIDER='openai'
CROW_OPENAI_STT_MODEL='gpt-4o-mini-transcribe'
CROW_STT_FALLBACK='system'

CROW_TTS_PROVIDER='openai'
CROW_OPENAI_TTS_MODEL='gpt-4o-mini-tts'
CROW_OPENAI_TTS_VOICE='marin'
CROW_TTS_FALLBACK='system'

CROW_OPENAI_API_KEY='...'
CROW_OPENAI_BASE_URL='https://api.openai.com'
```

Production clients should not call OpenAI directly. The OpenAI key belongs on Crow Cloud:

```env
CROW_OPENAI_API_KEY='...'
CROW_OPENAI_BASE_URL='https://api.openai.com'
```

Cloud endpoints:

```text
POST /v1/voice/transcriptions
POST /v1/voice/speech
```

macOS client provider values:

```env
# Product path: route STT/TTS through Crow Cloud.
CROW_STT_PROVIDER='cloud'
CROW_TTS_PROVIDER='cloud'
CROW_CLOUD_BASE_URL='https://your-crow-api.run.app'

# Local backend smoke test.
CROW_CLOUD_BASE_URL='http://127.0.0.1:18089'
```

The macOS client automatically calls `/v1/devices/activate` when cloud voice is enabled and stores the returned `device_token` in Keychain.
If the local development server restarts with the memory store and the stored token becomes invalid, the client clears the stale token, reactivates the device, and retries the cloud voice request once.

Manual token overrides are still supported:

```env
CROW_DEVICE_TOKEN='...'
CROW_CLOUD_DEVICE_TOKEN='...'
CROW_CLOUD_DEV_TOKEN='...'
```

`CROW_CLOUD_DEV_TOKEN` is mainly for local development or admin smoke tests.

## Current Implementation

- `CROW_STT_PROVIDER=openai` records microphone audio as 16kHz mono PCM16 WAV and uploads it to `/v1/audio/transcriptions`.
- `CROW_STT_PROVIDER=cloud` records the same audio format and uploads it to Crow Cloud `/v1/voice/transcriptions`.
- While cloud STT is recording, macOS `SFSpeechRecognizer` can provide partial preview text for the Island. These partials are display-only; the final transcript still comes from Crow Cloud / OpenAI STT.
- Final transcript submission waits for the OpenAI transcription result before creating a Crow task.
- `CROW_TTS_PROVIDER=openai` posts assistant output to `/v1/audio/speech` and plays returned MP3 audio.
- `CROW_TTS_PROVIDER=cloud` posts assistant output to Crow Cloud `/v1/voice/speech` and plays returned MP3 audio.
- macOS `SFSpeechRecognizer` and `AVSpeechSynthesizer` remain fallback paths.
- Realtime code remains available behind `CROW_VOICE_PROVIDER=openai_realtime`, but it is no longer the V1 default path.

The macOS direct OpenAI path remains useful for development, but the product path should move through Crow Cloud to support subscriptions, usage tracking, and provider changes without client updates.
