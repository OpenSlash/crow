# Crow Roadmap

Status: draft · Last updated: 2026-11-20

## Service modes

Crow supports two ways to reach model services. Users pick one in Settings.

| Mode | Where model calls happen | Keys | Target |
| --- | --- | --- | --- |
| **Local** (default) | `crowd` daemon calls the provider directly | User's own API key, stored in Keychain | Open-source build |
| **Crow Cloud** | `crow-cloud` server (self-hosted locally or in the cloud) | Server-side | Commercial build |

`crow-cloud` stays as is. All new work below targets the daemon so that the local mode is complete on its own.

## Phase 0 — Local model provider (foundation)

- [ ] `apps/daemon/internal/llm`: provider interface (streaming chat + tool calls)
  - [ ] OpenAI-compatible client (OpenAI, DeepSeek, Kimi, Qwen, GLM, OpenRouter, Ollama, …)
  - [ ] Anthropic client
- [ ] Config: `CROW_AGENT_MODE=local|cloud`, `CROW_LLM_PROVIDER`, `CROW_LLM_BASE_URL`, `CROW_LLM_MODEL`, `CROW_LLM_API_KEY`; key saved to Keychain via SettingsService
- [ ] Proto: `AgentService.Respond` (server stream of deltas / tool events / done)
- [ ] Port system prompt and executor hand-off from `server/internal/server/openai_agent.go` into the daemon
- [ ] Client: extract `CrowCloudAgent` from `LegacyIsland.swift` into an `AgentClient` that routes to daemon or cloud by mode
- [ ] Settings UI: mode, provider, base URL, model, key, "Test connection"
- [ ] Update `.env.example` and README

## Phase 1 — Agent loop and status events

- [ ] Tool-calling loop in the daemon with a per-wake request cap (default 40)
- [ ] Tool `delegate_to_codex` replaces the keyword heuristic (`shouldFastDelegateToCodex`)
- [ ] Emit typed activity events: `thinking`, `reading`, `searching`, `writing`, `running`, `using_computer`
- [ ] Map ACP tool updates from Codex to the same activity events
- [ ] Island renders activity state (icon + short label)

## Phase 2 — Long-term memory

- [ ] Store at `~/Library/Application Support/Crow/memory/`: `PROFILE.md` + `topics/<topic>.md` + `journal/YYYY-MM-DD.md`
- [ ] Auto `git commit` on every change when Git is available
- [ ] Inject `PROFILE.md` into the system prompt; tools `memory_search`, `memory_read`, `memory_write`
- [ ] Settings: view folder, turn memory off, clear

## Phase 3 — Interruption

- [ ] Talk key cancels TTS playback, the streaming reply and pending tool steps
- [ ] Proto: `TaskService.CancelTask`; propagate context cancel to the agent loop and ACP executor
- [ ] Actions already in progress (a click, a key sequence) finish; held keys are released at once

## Phase 4 — Approval policy

- [ ] Policies: `every_turn` / `before_acting` / `once` (grant TTL, default 30 min) / `never`
- [ ] Scopes: `computer`, `terminal`, `codex`, `file_write`; terminal input always asks separately
- [ ] Persist grants with expiry in SQLite; show active grants in Settings with revoke
- [ ] Approval prompt on the island; system dialog when the island is hidden

## Phase 5 — Computer use

Off by default. Requires explicit opt-in with a risk notice.

- [ ] Swift `ComputerUseHost` in CrowMac
  - [ ] Screenshot (ScreenCaptureKit), scaled to model resolution with coordinate mapping
  - [ ] Mouse / keyboard via `CGEvent` (move, click, drag, scroll, type, key combo, hold ≤ 30 s)
  - [ ] Focus app / list windows
  - [ ] Permission checks and onboarding (Accessibility, Screen Recording)
- [ ] Bridge: CrowMac subscribes to `ComputerService.WatchCommands` stream from the daemon and replies with results
- [ ] Daemon tools: Anthropic computer-use tool for Claude; generic function schema for other providers
- [ ] Safety
  - [ ] Pause on user mouse/keyboard input; resume after 2 s idle; give up after 15 s
  - [ ] "See only" mode (screenshots, no input)
  - [ ] Release all held keys/buttons at turn end
  - [ ] Global stop hotkey; island shows a persistent "using computer" indicator
  - [ ] Never handle logins, passwords or payments; stop and hand back to the user
  - [ ] Only user-originated input can trigger computer use

## Phase 6 — Reminders

- [ ] SQLite `reminders` table + scheduler in the daemon
- [ ] Tools `reminder_create`, `reminder_list`, `reminder_cancel`
- [ ] Fire via island + macOS notification

## Later

- [ ] MCP client support as the extension mechanism
- [ ] Usage and cost tracking per provider
- [ ] On-device STT (whisper.cpp / SenseVoice) for fully offline voice
- [ ] Deduplicate `rnnoise_data.c` between `apps/macos` and `apps/island-native`
