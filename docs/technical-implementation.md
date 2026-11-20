# Crow Technical Implementation Plan

Crow uses Wails + Go as the main desktop application and local execution hub, React/TypeScript for the task console, and SwiftUI/AppKit as the macOS-native experience layer.

The implementation principle is:

> Go is the brain. Web is the console. Swift/AppKit is the macOS sensory and interaction layer.

## 1. Technical Direction

Crow should be macOS-first in product delivery and cross-platform by architecture.

First release:

- macOS only.
- Wails desktop app.
- Go local runtime embedded in the app.
- React/TypeScript task console.
- SwiftUI/AppKit helper for native macOS capabilities.

Future releases:

- Split Go runtime into a daemon if long-running tasks need to survive UI restarts.
- Add Windows platform adapter.
- Keep Linux as optional, mainly for developer users.

## 2. Stack Summary

```text
Main App:
- Wails
- Go
- React
- TypeScript

UI:
- React
- TypeScript
- Tailwind CSS
- Radix UI or lightweight headless components

Local Runtime:
- Go
- SQLite
- Event bus
- Tool registry
- Task engine
- Permission gate

macOS Native Layer:
- SwiftUI
- AppKit
- NSPanel
- NSStatusItem
- Accessibility APIs
- Keychain
- Native notifications

Automation:
- Playwright for controlled browser automation
- Browser extension later for current-tab context
- External adapters for Codex, Claude, and existing agent projects

AI:
- Model provider abstraction
- OpenAI-compatible adapter
- Anthropic adapter
- Gemini/Kimi-compatible adapters later

Voice:
- Push-to-talk first
- Cloud STT or Whisper
- System TTS first
```

## 3. Architecture Overview

```text
Crow Desktop App
├── Wails Shell
│   ├── React Task Console
│   ├── Command Input
│   ├── Approval Queue
│   ├── Workflow Views
│   └── Settings
│
├── Go Runtime
│   ├── Task Engine
│   ├── Planner
│   ├── Tool Registry
│   ├── Permission Gate
│   ├── Event Bus
│   ├── Memory Store
│   ├── Agent Connectors
│   └── Platform Adapter Interface
│
├── macOS Native Helper
│   ├── Menu Bar
│   ├── Floating Panel
│   ├── Global Shortcut
│   ├── Active App Detection
│   ├── Accessibility Permission
│   ├── Audio Capture Entry
│   ├── Keychain Access
│   └── Native Notifications
│
└── External Executors
    ├── Browser Automation
    ├── Email Provider APIs
    ├── Calendar Provider APIs
    ├── Codex Connector
    ├── Claude Connector
    └── Existing Agent Runtime
```

## 4. Component Responsibilities

### Wails App

Wails owns the main application lifecycle and connects the React UI to Go methods.

Responsibilities:

- Main app window.
- Settings window.
- Task console window.
- Calling Go backend methods from the frontend.
- Receiving runtime events and rendering live task state.
- Packaging the desktop app.

Wails should not own core task logic. It is the shell, not the product brain.

### React/TypeScript UI

React owns the visible task operating system.

Responsibilities:

- Command input.
- Voice input state display.
- Task timeline.
- Agent status.
- Approval queue.
- Research output.
- Email summary and draft preview.
- Workflow list.
- Memory and permission settings.

Recommended frontend stack:

```text
React
TypeScript
Tailwind CSS
Radix UI
Zustand or TanStack Store
TanStack Query where remote/cache state helps
```

The UI should subscribe to task events rather than polling task state where possible.

### Go Runtime

Go is Crow's local execution hub.

Responsibilities:

- Create, start, pause, resume, cancel, and complete tasks.
- Maintain task state.
- Emit task events.
- Register and run tools.
- Classify action risk.
- Request user approval.
- Store structured memory.
- Call model providers.
- Orchestrate external agents.
- Manage local processes.
- Persist logs and audit trails.
- Expose APIs to Wails and native helpers.

Core packages:

```text
runtime       Task engine and orchestration
planner       Intent parsing, task planning, step planning
tools         Browser, email, calendar, file, search, shell
agents        Codex, Claude, existing agent project adapters
memory        SQLite, vector memory, artifacts
permissions   Risk levels, approvals, policies
events        Task event bus and subscriptions
platform      macOS/Windows/Linux platform abstraction
models        LLM provider adapters
```

### SwiftUI/AppKit macOS Helper

SwiftUI/AppKit handles the parts that need native macOS quality or system APIs.

Responsibilities:

- Menu bar icon.
- Dynamic Island style floating panel.
- Global shortcut.
- Native approval mini-panel.
- Active app/window detection.
- Accessibility permission flow.
- Selected text or frontmost app context when possible.
- Native notifications.
- Keychain access.
- Audio capture entry points.

Swift should not implement task planning, tool orchestration, memory, or agent routing.

## 5. Process Model

### MVP: Single App Process

The first version should keep the Go runtime embedded in the Wails app.

```text
Crow.app
├── Wails WebView UI
├── Go Runtime
└── macOS Helper integration
```

Advantages:

- Fastest to build.
- Simple packaging.
- Simple debugging.
- Fewer moving parts.

Limitations:

- Long-running tasks are tied to app lifecycle.
- UI crashes can affect runtime.
- Harder to support headless execution.

This is acceptable for the MVP.

### Later: Runtime Daemon

Once Crow has reliable long-running tasks, split the runtime into a background service.

```text
Crow.app
├── Wails UI
└── Thin Go client

crowd
├── Task Engine
├── Tool Registry
├── Agent Connectors
├── Memory
└── Event Bus
```

Advantages:

- Tasks can continue after UI closes.
- CLI, browser extension, and mobile companion can connect to the same runtime.
- More resilient execution model.
- Better fit for a real Jarvis-like assistant.

Trade-offs:

- More complex install and upgrade flow.
- More security work.
- Requires daemon health checks and recovery.

The code should be structured so this split is possible without rewriting core modules.

## 6. IPC And Eventing

Crow needs events as a first-class architecture concept.

Initial event path:

```text
Go Runtime -> Wails Binding/Event -> React UI
```

Potential future event path:

```text
crowd daemon -> local WebSocket/SSE/gRPC -> Crow UI
```

Recommended internal event shape:

```go
type TaskEvent struct {
    ID        string         `json:"id"`
    TaskID    string         `json:"taskId"`
    StepID    string         `json:"stepId,omitempty"`
    Type      TaskEventType  `json:"type"`
    Title     string         `json:"title,omitempty"`
    Message   string         `json:"message,omitempty"`
    Payload   map[string]any `json:"payload,omitempty"`
    CreatedAt time.Time      `json:"createdAt"`
}
```

Core event types:

```text
task.created
task.started
task.paused
task.resumed
task.cancelled
task.completed
task.failed
step.started
step.completed
step.failed
tool.called
tool.completed
tool.failed
approval.required
approval.approved
approval.rejected
agent.started
agent.waiting
agent.completed
agent.failed
```

## 7. Core Domain Contracts

### Task

```go
type TaskStatus string

const (
    TaskPending         TaskStatus = "pending"
    TaskRunning         TaskStatus = "running"
    TaskWaitingApproval TaskStatus = "waiting_approval"
    TaskPaused          TaskStatus = "paused"
    TaskCompleted       TaskStatus = "completed"
    TaskFailed          TaskStatus = "failed"
    TaskCancelled       TaskStatus = "cancelled"
)

type Task struct {
    ID          string     `json:"id"`
    Title       string     `json:"title"`
    UserInput   string     `json:"userInput"`
    Status      TaskStatus `json:"status"`
    CreatedAt   time.Time  `json:"createdAt"`
    UpdatedAt   time.Time  `json:"updatedAt"`
    CompletedAt *time.Time `json:"completedAt,omitempty"`
}
```

### Tool

```go
type RiskLevel int

const (
    RiskReadOnly RiskLevel = iota
    RiskDraft
    RiskReversible
    RiskHigh
)

type Tool interface {
    Name() string
    Description() string
    RiskLevel() RiskLevel
    InputSchema() any
    Run(ctx context.Context, input any) (any, error)
}
```

### Approval

```go
type ApprovalRequest struct {
    ID             string         `json:"id"`
    TaskID         string         `json:"taskId"`
    Title          string         `json:"title"`
    Description    string         `json:"description"`
    RiskLevel      RiskLevel      `json:"riskLevel"`
    ProposedAction map[string]any `json:"proposedAction"`
    Preview        string         `json:"preview,omitempty"`
    CreatedAt      time.Time      `json:"createdAt"`
    ExpiresAt      *time.Time     `json:"expiresAt,omitempty"`
}

type ApprovalDecision struct {
    ApprovalID string    `json:"approvalId"`
    Approved   bool      `json:"approved"`
    Comment    string    `json:"comment,omitempty"`
    DecidedAt  time.Time `json:"decidedAt"`
}
```

### Platform Adapter

```go
type Platform interface {
    ShowFloatingPanel(ctx context.Context, state PanelState) error
    HideFloatingPanel(ctx context.Context) error
    RegisterGlobalShortcut(ctx context.Context, shortcut string) error
    GetActiveApp(ctx context.Context) (ActiveApp, error)
    GetSelectedText(ctx context.Context) (string, error)
    RequestPermission(ctx context.Context, permission Permission) error
    Notify(ctx context.Context, notification Notification) error
}
```

macOS implementation should call the SwiftUI/AppKit helper. Windows and Linux implementations can be added later.

## 8. macOS Native Integration

The macOS helper should be isolated behind the Platform interface.

Recommended helper architecture:

```text
Go Platform Adapter
  ↕ local IPC
macOS Helper
  ├── SwiftUI views
  ├── AppKit windows
  ├── Accessibility APIs
  ├── Keychain
  └── Notifications
```

IPC options:

- Unix domain socket: good first choice for local-only communication.
- Local HTTP: easiest to debug.
- gRPC: good if typed contracts become important.
- XPC: most native on macOS, but more complex.

MVP recommendation:

> Use local HTTP or Unix domain socket first. Move to XPC only if macOS security and helper lifecycle require it.

Native capabilities to prioritize:

1. Menu bar status item.
2. Global shortcut.
3. Floating panel.
4. Native notification.
5. Accessibility permission request.
6. Active app detection.
7. Keychain storage.
8. Audio capture entry.

## 9. Data Storage

Use SQLite as the default local store.

Tables:

```text
tasks
task_steps
task_events
approval_requests
tool_runs
agent_runs
memories
workflow_templates
settings
artifacts
```

Storage principles:

- Store task state and event history separately.
- Keep raw tool outputs as artifacts when large.
- Keep approval decisions for auditability.
- Encrypt secrets through Keychain on macOS.
- Do not store API keys in SQLite.

Vector memory options:

- Start without vector memory if MVP does not need it.
- Add sqlite-vec when local semantic retrieval becomes necessary.
- Consider LanceDB only if memory scale grows.

## 10. Tool And Agent Integration

### Tool Registry

All tools should be registered with:

- Name
- Description
- Input schema
- Risk level
- Runtime implementation

Initial tools:

```text
browser.search
browser.open
browser.extract
email.list
email.summarize
email.draft_reply
email.send
file.read
file.write
calendar.list
agent.codex.run
agent.claude.run
```

High-risk tools must always pass through Permission Gate.

### Agent Connectors

Codex, Claude, and existing agent projects should be wrapped as connectors.

Connector responsibilities:

- Start task.
- Stream status.
- Stream logs.
- Surface permission requests.
- Return summary.
- Handle cancellation.

Example interface:

```go
type AgentConnector interface {
    Name() string
    Start(ctx context.Context, req AgentTaskRequest) (AgentRun, error)
    Events(ctx context.Context, runID string) (<-chan AgentEvent, error)
    Cancel(ctx context.Context, runID string) error
}
```

## 11. Browser Strategy

MVP:

- Use Playwright for controlled browser automation.
- Use browser extraction for research workflows.
- Keep credentials and logged-in sessions explicit and user-controlled.

Later:

- Add Chrome extension for current-tab context.
- Add DOM extraction from the user's active tab.
- Add browser-side approval overlays for form submissions.

Principle:

> Prefer APIs first, controlled browser automation second, screen-level automation last.

## 12. Voice Strategy

MVP:

- Push-to-talk.
- Send audio to STT provider or local Whisper.
- Show transcript before or during execution.
- Use system TTS for short responses.
- Support interrupt commands.

Supported interrupt commands:

```text
pause
continue
cancel
approve
reject
rewrite
show sources
open task
```

Later:

- Wake word.
- Local always-on detection.
- Better TTS voices.
- Speaker recognition.

## 13. Security And Permissions

Crow must be safe by default.

Risk levels:

```text
Level 0: Read-only
Examples: read webpage, read email title, read calendar.

Level 1: Draft generation
Examples: draft email, prepare report, prepare command, fill form without submitting.

Level 2: Reversible execution
Examples: move file, create calendar event, save document, archive email.

Level 3: High-risk execution
Examples: send email, delete file, pay, commit code, publish content, run dangerous command.
```

Default behavior:

- Level 0 runs automatically.
- Level 1 runs automatically and shows the result.
- Level 2 depends on user settings.
- Level 3 always requires explicit approval.

Security requirements:

- API keys stored in Keychain on macOS.
- All high-risk actions create approval records.
- Tool calls are logged.
- User can inspect task history.
- User can cancel long-running tasks.
- Shell access is disabled by default unless developer mode is enabled.

## 14. Cross-Platform Strategy

Crow should not ship cross-platform in V1, but the architecture must support it.

Cross-platform core:

- Task engine
- Planner
- Event bus
- Tool registry
- Permission model
- Memory store
- Agent connectors
- Research workflow
- Email workflow

Platform-specific adapters:

- Floating panel
- Menu bar / system tray
- Global shortcut
- Active app detection
- Accessibility permissions
- Screen capture
- Native notifications
- Audio capture
- Keychain / credential store

Platform roadmap:

```text
V1: macOS only
V2: macOS polished, runtime boundaries hardened
V3: Windows private beta
V4: Windows public release
V5: Linux optional
```

## 15. Repository Structure

Recommended initial structure:

```text
crow/
├── apps/
│   └── desktop/
│       ├── frontend/
│       ├── backend/
│       ├── wails.json
│       └── go.mod
│
├── packages/
│   ├── runtime/
│   ├── planner/
│   ├── tools/
│   ├── agents/
│   ├── memory/
│   ├── permissions/
│   ├── events/
│   ├── platform/
│   └── models/
│
├── native/
│   ├── macos/
│   ├── windows/
│   └── linux/
│
├── docs/
└── scripts/
```

For MVP, this can be simplified:

```text
crow/
├── apps/desktop/
├── internal/
│   ├── runtime/
│   ├── tools/
│   ├── agents/
│   ├── memory/
│   ├── permissions/
│   ├── events/
│   └── platform/
├── native/macos/
├── docs/
└── scripts/
```

Use the simpler structure unless multiple apps or packages are needed immediately.

## 16. MVP Implementation Plan

### Phase 1: Wails Skeleton

Deliverables:

- Create Wails app.
- Add React/TypeScript frontend.
- Add basic app layout.
- Add Go backend bindings.
- Add SQLite initialization.
- Add task creation and list view.

### Phase 2: Task Runtime

Deliverables:

- Task model.
- Task state machine.
- Task event bus.
- Task timeline UI.
- In-memory tool registry.
- Persistent task events.

### Phase 3: Permission Gate

Deliverables:

- Risk levels.
- Approval request model.
- Approval queue UI.
- Approve/reject flow.
- Tool execution blocked by approval where required.

### Phase 4: Agent Connector

Deliverables:

- Adapter for existing agent runtime.
- Codex connector.
- Claude connector.
- Agent status events.
- Logs and completion summary.

### Phase 5: macOS Native Helper

Deliverables:

- Menu bar item.
- Global shortcut.
- Floating panel.
- Native notifications.
- Permission check flow.

### Phase 6: Web Research Workflow

Deliverables:

- Search tool.
- Browser open/extract tool.
- Multi-source summary.
- Markdown artifact output.
- Source list in UI.

### Phase 7: Voice MVP

Deliverables:

- Push-to-talk.
- STT integration.
- Transcript display.
- TTS short response.
- Interrupt commands.

## 17. Key Engineering Decisions

### Use Wails For The Main App

Rationale:

- Good fit for Go-first local runtime.
- Lighter than Electron.
- Supports web UI development speed.
- Keeps cross-platform path open.

### Use Go For Core Runtime

Rationale:

- Strong concurrency.
- Good process management.
- Good fit for long-running local services.
- Easy to ship as a single binary.
- Better operational discipline than a frontend-driven runtime.

### Use React/TypeScript For The Console

Rationale:

- Fast iteration for complex UI.
- Strong ecosystem for timelines, tables, forms, and state.
- Good fit for task console and workflow editor.

### Use SwiftUI/AppKit Only For macOS Native Capabilities

Rationale:

- Best fit for menu bar, floating panels, shortcuts, accessibility, and native permissions.
- Avoids binding core product logic to macOS.
- Keeps Windows path open.

### Start Single-Process, Design For Daemon

Rationale:

- MVP speed matters.
- Long-running execution will eventually need a daemon.
- Clean internal contracts make the later split manageable.

## 18. Open Technical Questions

These should be answered during MVP development:

- Should the first macOS helper be embedded or a separate helper app?
- Should IPC use local HTTP, Unix socket, or gRPC?
- Should Playwright run as a bundled dependency or user-installed dependency?
- Which email provider should be implemented first: Gmail, Outlook, or IMAP?
- Should model calls be BYOK-only in MVP?
- Should workflow templates be static JSON first or editable in UI from day one?
- How much task history should be retained by default?
- Which high-risk actions should be hard-blocked in V1?

## 19. Final Recommendation

Use this implementation approach:

> Crow uses Wails + Go as the main desktop app and local execution hub, React/TypeScript as the task console, and SwiftUI/AppKit as the macOS-native experience layer.

Delivery should be:

```text
V1: macOS Wails app with embedded Go runtime
V2: stronger macOS helper and polished floating UI
V3: optional background daemon
V4: Windows platform adapter
```

The most important rule:

> Keep Crow's core runtime platform-neutral. Let platform-specific code provide capabilities, not own product logic.
