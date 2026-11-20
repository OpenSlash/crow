# Runtime Settings

Crow Console now provides a runtime settings panel for local executor and native Island configuration.

## Storage

Desktop persists settings in SQLite:

```text
runtime_settings(key, value, updated_at)
```

It also writes a JSON mirror for the native Island:

```text
~/Library/Application Support/Crow/runtime-settings.json
```

The JSON file uses environment variable keys, for example:

```json
{
  "CROW_VOICE_PROVIDER": "system",
  "CROW_STT_PROVIDER": "openai",
  "CROW_OPENAI_STT_MODEL": "gpt-4o-mini-transcribe",
  "CROW_TTS_PROVIDER": "openai",
  "CROW_OPENAI_TTS_MODEL": "gpt-4o-mini-tts",
  "CROW_OPENAI_TTS_VOICE": "marin",
  "CROW_OPENAI_REALTIME_MODEL": "gpt-realtime",
  "CROW_OPENAI_REALTIME_VOICE": "marin",
  "CROW_OPENAI_REALTIME_TURN_DETECTION": "semantic_vad",
  "CROW_STT_LANGUAGE": "zh",
  "CROW_TTS_VOICE": "",
  "CROW_TTS_STREAMING": "true"
}
```

## Supported Settings

- Voice provider
- STT provider
- OpenAI STT model
- TTS provider
- OpenAI TTS model
- OpenAI TTS voice
- OpenAI Realtime API key
- OpenAI Realtime model
- OpenAI Realtime voice
- OpenAI Realtime turn detection
- STT language
- TTS provider
- TTS voice
- TTS streaming
- Island screen
- Island hotkey
- Island idle close seconds

## Runtime Precedence

Desktop startup:

```text
.env -> SQLite runtime_settings -> process env
```

Native Island:

```text
process env -> runtime-settings.json -> .env
```

This keeps `.env` useful for development while letting the product move toward UI-managed configuration.
