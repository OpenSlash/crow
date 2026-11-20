# Voice Task Flow

Crow Island uses a confirm-before-execute voice flow.

## Flow

```text
Wake Island
-> request speech and microphone permission
-> stream STT partial transcript
-> stop on click or silence threshold
-> show "Confirm Task"
-> left-click to create task
-> right-click to cancel
-> write voice-command.json
-> Crow Desktop creates the task
```

## States

`Listening`
: Audio is streaming and partial transcript is shown live.

`Transcribing`
: Recording has stopped and Crow is finalizing the transcript.

`Confirm Task`
: Transcript is ready but no task has been created yet. This protects against accidental execution from noisy or incorrect STT.

`Task Created`
: The confirmed transcript was written to `voice-command.json` for the desktop runtime to consume.

## Product Rule

Voice should not directly execute a task after silence detection. Silence only ends capture. A separate user confirmation creates the task.
