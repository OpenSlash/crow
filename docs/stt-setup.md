# Crow Streaming STT Setup

Crow Island uses macOS native streaming speech recognition:

```text
AVAudioEngine microphone buffers
-> Speech framework partial transcription
-> Island displays live text
-> silence threshold ends capture
-> transcript becomes a Crow task
```

It does not wait for a full audio file before transcribing.

## Configuration

Fill `.env` in the project root:

```bash
CROW_STT_LANGUAGE='zh'
CROW_RNNOISE_ENABLED='true'
CROW_ISLAND_SCREEN='builtin'
CROW_ISLAND_HOTKEY='ctrl+option+space'
CROW_ISLAND_IDLE_CLOSE_SECONDS='8'
CROW_ISLAND_VOICE_IDLE_CLOSE_SECONDS='12'
CROW_ISLAND_VOICE_NO_RESPONSE_CLOSE_SECONDS='24'
CROW_ISLAND_VOICE_CONTINUE_DELAY_SECONDS='0.75'
CROW_ISLAND_VOICE_NO_SPEECH_CLOSE_SECONDS='12'
```

Then restart the native Island:

```bash
cd /path/to/crow
./scripts/run-native-island.sh
```

Press `Control + Option + Space` to wake Crow. Speak normally; the Island shows partial transcript text while you speak. After silence, Crow submits the recognized text as a task.

After submission, the Island stays open for conversational output. Click the Island or right-click it to close manually.

When a direct voice response completes, Crow automatically starts listening again after `CROW_ISLAND_VOICE_CONTINUE_DELAY_SECONDS`. If no follow-up speech is detected within `CROW_ISLAND_VOICE_NO_SPEECH_CLOSE_SECONDS`, the Island closes. Phrases such as "不用继续", "先这样", or "end conversation" end the conversation after the current response.

## Language

Supported examples:

```bash
CROW_STT_LANGUAGE='zh'
CROW_STT_LANGUAGE='zh-CN'
CROW_STT_LANGUAGE='en-US'
```

`zh` maps to `zh-CN`.

## Noise Suppression

Crow Island includes RNNoise before Apple Speech when the microphone format is 48kHz mono Float32. The denoised signal is used for both streaming transcription and audio-level detection.

```bash
CROW_RNNOISE_ENABLED='true'
```

Set it to `false` to bypass RNNoise and send raw microphone buffers to Speech:

```bash
CROW_RNNOISE_ENABLED='false'
```

## Permissions

The first run may ask for:

- Microphone access
- Speech Recognition access

Because the current native Island is launched through `swift run`, macOS may show the requesting process as Terminal or the Swift executable.

## Hotkey

Default:

```bash
Control + Option + Space
```

Override:

```bash
CROW_ISLAND_HOTKEY='ctrl+shift+space'
```

Supported modifiers:

- `cmd`
- `shift`
- `ctrl`
- `option`

Current supported key:

- `space`
