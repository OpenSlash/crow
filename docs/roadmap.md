# Crow Roadmap

Status: draft · Last updated: 2026-11-20

## Service modes

Crow supports two ways to reach model services. Users pick one in Settings.

| Mode | Where model calls happen | Keys | Target |
| --- | --- | --- | --- |
| **Local** (default) | `crowd` daemon calls the provider directly | User's own API key, stored in Keychain | Open-source build |
| **Crow Cloud** | `crow-cloud` server (self-hosted locally or in the cloud) | Server-side | Commercial build |

`crow-cloud` stays as is. All new work below targets the daemon so that the local mode is complete on its own.

## Phase 0 — Local model provider (foundation) ✅

- [x] `apps/daemon/internal/llm`: provider interface (streaming chat)
  - [x] OpenAI-compatible client (OpenAI, DeepSeek, Moonshot, Qwen, GLM, OpenRouter, Ollama, custom)
  - [x] Anthropic client
- [x] Config: `CROW_AGENT_MODE=local|cloud`, `CROW_LLM_PROVIDER`, `CROW_LLM_BASE_URL`, `CROW_LLM_MODEL`, `CROW_LLM_API_KEY` (falls back to `CROW_OPENAI_*`)
- [x] Daemon serves `/v1/agent/respond` and `/v1/agent/respond-stream` with the same wire format as crow-cloud (instead of a new proto service), guarded by the session token
- [x] Port system prompt and executor hand-off from crow-cloud into `apps/daemon/internal/agent`
- [x] Client: `AgentClient.swift` routes to daemon or cloud by mode; removed the duplicate Swift-side OpenAI fallback
- [x] Settings: mode, provider, base URL, model, key (Keychain, per provider, write-only to the daemon), "Test" button
- [x] Update `.env.example` and README

## Phase 1 — Agent loop and status events ✅

- [x] Tool calling in `internal/llm` (OpenAI + Anthropic, streamed)
- [x] Tool-calling loop in the daemon with a per-turn request cap (`CROW_AGENT_MAX_STEPS`, default 40)
- [x] Tool `delegate_to_codex` replaces the keyword heuristics (daemon and `shouldFastDelegateToCodex`); the model writes the task sent to Codex
- [x] SSE `activity` event: `thinking`, `reading`, `searching`, `writing`, `running`, `using_computer`
- [x] Map ACP tool kinds from Codex to activity labels (task subtitle)
- [x] Island shows the activity label while the agent works
- [ ] Per-activity icons on the island (design pending)

## Phase 2 — Long-term memory ✅

- [x] Store at `~/Library/Application Support/Crow/memory/`: `PROFILE.md` + `topics/<topic>.md` + `journal/YYYY-MM-DD.md`
- [x] Auto `git commit` on every change when Git is available
- [x] Inject `PROFILE.md` into the system prompt; tools `memory_search`, `memory_read`, `memory_write`
- [x] Settings: view folder, turn memory off, clear

## Phase 3 — Interruption ✅

- [x] Talk key cancels TTS playback, the streaming reply and pending tool steps (barge-in while Crow is busy; a delegated Codex task keeps running)
- [x] Proto: `TaskService.CancelTask`; propagate context cancel to the agent loop and ACP executor (`session/cancel`, then the process group is killed after a 3 s grace)
- [x] A tool step already running finishes; pending ones are skipped. Releasing held keys lands with computer use (Phase 5)
- [x] Stop a running task from the menu bar ("Stop Task")

## Phase 4 — Approval policy ✅

- [x] Policies: `every_turn` / `before_acting` (once per task) / `once` (grant TTL, default 30 min, `CROW_APPROVAL_GRANT_MINUTES`) / `never`
- [x] Scopes: `computer`, `terminal`, `codex`, `file_write`; terminal cannot be set to `never` (raised to `once`). Defaults: terminal `every_turn`, others `before_acting`
- [x] ACP permission requests map by tool kind: execute → terminal, edit/delete/move → file_write, others → codex
- [x] Persist grants with expiry in SQLite; Settings shows active grants with Revoke All
- [x] Approval prompt on the island (existing). No system-dialog fallback: the island is always on screen

## Phase 5 — Computer use ✅

Off by default: Settings → "Let Crow use this Mac" shows a risk notice before turning it on.

- [x] Swift `CrowComputerUseHost` in CrowMac
  - [x] Screenshot (ScreenCaptureKit) of the main display, scaled to ≤ 1280 px wide, JPEG; coordinates map back to screen points
  - [x] Mouse / keyboard via `CGEvent`: click (1–3, left/right/middle), move, drag, scroll, type, key combos; `open_app`
  - [x] Permission checks and onboarding (Screen Recording, Accessibility) in Settings
  - [x] `zoom` (re-capture a region at full detail), `windows` (list app windows), `focus` (raise an app or one of its windows)
  - [x] Results include the pointer position and the front app/window; actions can skip the screenshot (`screenshot: false`)
  - [x] `elements`: numbered accessibility controls of the front window and menu bar, drawn on the screenshot (Set-of-Mark); `click` by element uses AXPress; `set_value` fills text fields
  - [x] Hardening: one computer task at a time, type ≤ 2000 chars and stops when the user types, refuses secure input, AX timeouts, layout-aware shortcuts
  - [x] MCP server (`crowctl mcp`) exposes the same tool to other agents through `ComputerService.Perform`, under Crow's switch, approvals and see-only mode
  - [ ] Hold keys or mouse buttons for a duration; multiple displays
  - [ ] Optional grounding model (e.g. UI-TARS) for coordinate-free targeting
  - [ ] Background key delivery to a process without focusing it
  - [ ] Run the input engine in a separate process (needs its own TCC permissions)
- [x] Bridge: CrowMac subscribes to `ComputerService.WatchCommands` and replies with `SubmitResult`
- [x] Daemon: `use_computer` hand-off creates a `computer` task; the computer executor runs its own tool loop and approvals (scope `computer`); tool results carry screenshots (OpenAI: follow-up user image message; Anthropic: image blocks in `tool_result`); only the 2 latest screenshots are kept
- [ ] Anthropic native `computer_toolset_20260801` for Claude (all providers use the generic `computer` function tool for now)
- [x] Safety
  - [x] Wait while the user uses the mouse/keyboard (2 s idle); give up after 15 s
  - [x] "See only" mode (screenshots, no input)
  - [x] Release held modifier keys and mouse buttons when a task ends
  - [x] Global stop shortcut ⌃⌥⎋ cancels the active task; the island shows the task's current action
  - [x] Never handle logins, passwords or payments (prompt rule; typing into password fields is refused)
  - [x] Only user-originated input can trigger computer use (voice/command turns only)

## Phase 6 — Reminders ✅

- [x] SQLite `reminders` table + scheduler in the daemon (checks every 5 s)
- [x] Tools `reminder_create` (`at` "YYYY-MM-DD HH:MM" / "HH:MM", or `in_minutes`), `reminder_list`, `reminder_cancel`; the system prompt carries the current local time
- [x] Fire via island (spoken) + macOS notification; fired reminders stay in the runtime snapshot until the app acknowledges them, and ones that fired while Crow was off only notify
- [ ] Repeating reminders

## Later

- [ ] MCP client support as the extension mechanism
- [ ] Usage and cost tracking per provider
- [ ] On-device STT (whisper.cpp / SenseVoice) for fully offline voice
- [ ] Deduplicate `rnnoise_data.c` between `apps/macos` and `apps/island-native`
