# Crow E2E Smoke Checks

Use these checks to verify the runtime loop before testing the notch UI or voice input.

Core loop:

```text
CreateTask -> WatchTask -> task events -> terminal event -> GetTask detail
```

## Start The Daemon

```bash
cd apps/daemon
go run ./cmd/crowd
```

The daemon writes its session to:

```text
~/Library/Application Support/Crow/runtime/session.json
```

## Mock Runtime Smoke

This verifies the daemon, SQLite store, task creation, event persistence, and `WatchTask` stream.

```bash
cd apps/daemon
go run ./cmd/crowctl \
  --create-task "crowctl stream smoke" \
  --mode general \
  --watch \
  --timeout 15s
```

Expected terminal event:

```text
event: task.completed ...
```

The command also prints final task detail from `GetTask`.

## Codex Delegation Smoke

This verifies Crow can delegate a real task to Codex and receive streamed events.

```bash
cd apps/daemon
go run ./cmd/crowctl \
  --create-task "用一句话回答：1+1 等于几" \
  --mode agent \
  --watch \
  --timeout 120s
```

Expected behavior:

- `executor.selected` shows the configured executor routing.
- `executor.output`, `tool.started`, `executor.plan`, or `voice.output.segment` events appear during execution.
- `task.completed` contains the final conclusion.

If this falls back to the mock executor, check the installed executor manifest under `~/.crow/executors` and whether the ACP command starts successfully.

## macOS Client Smoke

```bash
cd apps/macos
CROW_ISLAND_SCREEN=main swift run CrowMac
```

Then run a `crowctl --create-task ... --watch` command in another terminal. The native app should update its active task and the notch island should reflect the streamed task state.

You can also use the status bar menu:

```text
Crow -> Run Agent Smoke
```

This submits a fixed `mode=agent` task through the same native `CreateTask` path used after voice transcription. It is the fastest way to verify:

- the native app can reach the daemon
- `mode=agent` routes to Codex
- `WatchTask` updates the app and island state
- `voice.output.segment` can drive the speaking state

## Notch Voice Smoke

Use this only after the macOS client smoke passes.

1. Launch `CrowMac`.
2. Wake the notch island with the configured hotkey.
3. Speak a short command: `用一句话回答，8 加 9 等于几`.
4. Stop speaking and wait for silence detection.
5. Confirm the island shows the recognized text, then `Crow is thinking/responding`.
6. Confirm the final island message is `8+9 等于 17` or equivalent.

If no task is created:

- Check macOS Speech Recognition permission.
- Check microphone permission.
- Check whether the island shows `No transcript recognized`.
- Use `Crow -> Run Agent Smoke` to isolate whether the failure is only STT/audio.

## Validation Commands

```bash
GOSUMDB=off go test ./apps/daemon/... ./server/...
cd apps/macos && swift build
```
