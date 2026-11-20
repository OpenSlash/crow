# Crow macOS Native Architecture

Crow will prioritize a macOS-native client. Windows is not a first-stage product target because Crow's primary interaction model depends on macOS-specific surfaces: the notch island, status bar, global hotkeys, microphone permissions, and native window behavior.

## Direction

The native macOS client and notch island should become one Swift project. The Go layer remains the reusable core runtime.

```text
Crow.app
  SwiftUI/AppKit shell
  - Notch island
  - Status bar
  - Main window
  - Settings
  - Voice capture/playback
  - Permission onboarding

crowd
  Go core runtime
  - Agent orchestration
  - Task database
  - Executor Adapter Kit
  - Codex/Hermes/OpenClaw delegation
  - Approval state machine
  - STT/TTS provider integration
  - Local file/process/tool execution
```

The Swift app owns product experience. The Go daemon owns reasoning, state, and execution.

## Project Shape

Target structure:

```text
apps/macos/
  Crow.xcodeproj or Package.swift
  Sources/CrowApp/
    App/
    Island/
    StatusBar/
    Windows/
    Voice/
    Settings/
    RPC/

apps/daemon/
  cmd/crowd/
  internal/agent/
  internal/executors/
  internal/tasks/
  internal/approvals/
  internal/runtime/
  internal/speech/

proto/crow/v1/
  crow.proto
  task.proto
  voice.proto
  approval.proto
  settings.proto
```

The current `apps/island-native` and `apps/status-native` should be folded into `apps/macos` instead of remaining separate helper apps. The previous `apps/desktop` Wails app has been removed from the runnable product surface; new client work should land in `apps/macos`.

## Transport

Use ConnectRPC as the default local RPC layer.

Reasons:

- It has official Go and Swift implementations and code generation.
- It supports the Connect protocol and can be compatible with gRPC/gRPC-Web where needed.
- It uses HTTP semantics, which keeps local debugging easier than raw gRPC.
- It supports streaming, which Crow needs for transcripts, task events, and speech output.

Default local binding:

```text
127.0.0.1:{dynamic_port}
```

Startup flow:

1. `Crow.app` starts.
2. Swift launches embedded `crowd`.
3. `crowd` binds to localhost on an available port.
4. `crowd` writes a session file:

```text
~/Library/Application Support/Crow/runtime/session.json
```

5. Swift reads `session.json` and connects via ConnectRPC.
6. Swift subscribes to runtime streams.

`session.json`:

```json
{
  "pid": 12345,
  "baseURL": "http://127.0.0.1:43189",
  "token": "random-local-session-token",
  "startedAt": "2026-07-08T10:00:00Z"
}
```

The local token prevents unrelated local processes from calling the daemon casually. This is not a complete security boundary, but it is enough for the first local-only implementation.

## RPC Surface

Initial services:

```proto
service CrowRuntimeService {
  rpc GetSnapshot(GetSnapshotRequest) returns (RuntimeSnapshot);
  rpc WatchRuntime(WatchRuntimeRequest) returns (stream RuntimeEvent);
}

service TaskService {
  rpc CreateTask(CreateTaskRequest) returns (Task);
  rpc GetTask(GetTaskRequest) returns (TaskDetail);
  rpc ListTasks(ListTasksRequest) returns (ListTasksResponse);
  rpc WatchTask(WatchTaskRequest) returns (stream TaskEvent);
}

service VoiceService {
  rpc StartVoiceSession(StartVoiceSessionRequest) returns (VoiceSession);
  rpc StreamAudio(stream AudioChunk) returns (stream VoiceEvent);
  rpc CancelVoiceSession(CancelVoiceSessionRequest) returns (CancelVoiceSessionResponse);
}

service ApprovalService {
  rpc ListPendingApprovals(ListPendingApprovalsRequest) returns (ListPendingApprovalsResponse);
  rpc DecideApproval(DecideApprovalRequest) returns (Approval);
}

service SettingsService {
  rpc GetSettings(GetSettingsRequest) returns (Settings);
  rpc SaveSettings(SaveSettingsRequest) returns (Settings);
}
```

Streaming responsibilities:

- `WatchRuntime`: island/status bar state, active task, approvals, voice state.
- `WatchTask`: task progress, executor output, final conclusion.
- `StreamAudio`: bidirectional voice capture, partial transcript, final transcript, speaking events.

## Latency Model

The Swift app should not wait for database polling or file watching for primary UX.

Expected hot path:

```text
Microphone frame
-> Swift voice capture
-> ConnectRPC streaming chunk
-> Go STT/session pipeline
-> partial transcript event
-> Swift island text update
```

For local UX, target update budgets:

- Audio level animation: local Swift only, under 16 ms.
- Partial transcript display: under 150 ms after STT provider response.
- Runtime state updates: under 50 ms after Go emits event.
- Approval button response: under 100 ms local state update, executor continuation async.

The notch island animation should be driven locally in Swift. Go only sends semantic state.

## State Ownership

Go owns:

- task records
- task events
- executor state
- approvals
- settings persistence
- agent context
- model/provider configuration

Swift owns:

- window state
- island animation state
- menu/status item state
- microphone permission prompts
- audio device selection UI
- local waveform rendering
- transient UI affordances

Shared contract:

- protobuf messages define persisted and streamed domain state.
- Swift can cache snapshots but must treat Go as source of truth for tasks and execution.

## Migration Plan

Phase 0: native baseline

- Keep `apps/macos` as the only runnable client.
- Keep `apps/island-native` and `apps/status-native` only as temporary reference implementations until fully folded into `apps/macos`.
- Do not add new Wails or React desktop code.

Phase 1: Go core daemon

- Create `apps/daemon/cmd/crowd`.
- Expose a small ConnectRPC API:
  - `GetSnapshot`
  - `CreateTask`
  - `ListTasks`
  - `WatchRuntime`
  - `DecideApproval`
- Keep Codex adapter intact.

Phase 2: create unified macOS app

- Create `apps/macos`.
- Merge status bar and notch island into one Swift app.
- Launch and supervise `crowd`.
- Connect to `crowd` via ConnectRPC.
- Implement main window with history/settings only.

Phase 3: voice-first loop

- Swift captures microphone and drives waveform locally.
- Go receives streamed audio or final audio chunks depending on STT provider.
- Swift displays partial transcript and assistant output in the island.
- TTS output events drive island speaking animation.

Phase 4: native parity

- Native macOS app reaches parity for:
  - task history
  - settings
  - Codex delegation
  - approvals
  - status bar
  - notch island
  - voice input/output
- Remove temporary native helper apps after `apps/macos` owns their behavior.

## Build And Packaging

Final distribution should package:

```text
Crow.app
  Contents/MacOS/Crow
  Contents/Resources/crowd
```

Swift launches the embedded daemon. The daemon should never be installed globally in the first version.

Required runtime behavior:

- If `crowd` is not running, Swift starts it.
- If `crowd` crashes, Swift shows degraded UI and offers restart.
- If Swift quits, it asks `crowd` to stop gracefully.
- If graceful stop fails, Swift kills only its own child daemon.

## Decision

Crow should move toward:

```text
SwiftUI/AppKit macOS client + Go daemon + ConnectRPC
```

This keeps the product macOS-native without throwing away the Go execution core.
