# Voice Output Protocol

Crow voice output is the assistant response channel after a task has useful feedback for the user.

It should be treated as a runtime capability, not as a UI detail. The desktop runtime decides what should be spoken, and the native Island decides how to render and play it.

## Product Rule

Voice output is for short, timely responses:

- task accepted
- task needs approval
- task completed
- task failed with a human-readable reason
- direct conversational answer

Long reports, code diffs, logs, and large research summaries should stay in the console or artifact view. Crow may speak a short summary and offer to open the full result.

Tool output is not user speech. Shell output, browser extraction, search results, logs, and approval previews should feed the agent context and task timeline, but Crow should not speak them directly.

The spoken stream should come from the agent's user-facing response:

```text
tool output
-> agent context
-> agent response delta
-> Crow phrase segment
-> TTS playback
```

## Streaming Model

Voice output should support streaming because the Jarvis experience depends on low latency.

```text
assistant text stream
-> sentence or phrase segmentation
-> TTS request per segment
-> audio chunks
-> Island playback queue
-> interruption if user speaks or cancels
```

Streaming is not the same as speaking every token. Crow should buffer until a natural phrase boundary, then synthesize and play that segment while the next segment is still being generated.

Recommended segment boundaries:

- Chinese punctuation: `，` `。` `？` `！`
- English punctuation: `,` `.` `?` `!`
- max latency window: 600-900 ms
- max segment length: 80-160 characters

## Runtime Settings

```bash
CROW_TTS_PROVIDER='system'
CROW_TTS_VOICE=''
CROW_TTS_STREAMING='true'
```

`CROW_TTS_PROVIDER`
: `system`, `openai`, `elevenlabs`, or `off`.

`CROW_TTS_VOICE`
: Provider-specific voice id. Empty means provider default.

`CROW_TTS_STREAMING`
: Enables phrase-by-phrase streaming playback. If disabled, Crow speaks only after the final assistant response is ready.

## Provider Strategy

Primary: `openai_realtime`
: Use OpenAI Realtime for low-latency voice input and voice output when the user provides their own API key. Crow should use it as the Jarvis-grade voice layer, not as the task executor.

Fallback: `system`
: Use native macOS speech recognition and system TTS when Realtime is not configured, unavailable, or disabled. This keeps Crow usable without a model service.

Later: voice profiles
: Let users choose voices by persona, task type, or language.

## Realtime Boundary

OpenAI Realtime is the voice transport and conversational audio layer.

Crow still owns:

- task creation
- executor routing
- Codex delegation
- approval state
- task history
- final response policy

Initial behavior:

```text
AVAudioEngine
-> OpenAI Realtime
-> user transcript
-> Crow CreateTask(mode=agent)
-> Codex / executor
-> voice.output.segment
-> OpenAI Realtime or system fallback playback
```

Crow should not let the voice model directly mutate files or run tools in the first Realtime phase. All powerful actions continue through Crow tasks and approvals.

## Events

Voice output should be represented as normalized task events:

- `voice.output.started`
- `voice.output.segment`
- `voice.output.completed`
- `voice.output.cancelled`
- `voice.output.failed`

Suggested event payload fields:

```json
{
  "taskId": "task_...",
  "provider": "system",
  "voice": "default",
  "segmentIndex": 2,
  "text": "我已经整理好了摘要。",
  "status": "playing"
}
```

## Island States

The Island should distinguish:

`speaking`
: Crow is currently playing audio.

`interrupted`
: User started speaking or cancelled playback.

`muted`
: TTS is disabled by settings or current focus mode.

The visual language should stay compact: the right side can show audio playback amplitude, while the left Crow mark remains the state identity.

## Interruption

User speech has priority over Crow speech.

```text
User starts speaking
-> stop current playback
-> clear queued TTS segments
-> switch Island to listening
```

Approvals also have priority. If a task reaches `waiting_approval`, Crow should stop long speech and speak only the approval prompt.
