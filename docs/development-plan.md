# Crow MVP Development Plan

This document breaks the MVP into implementation milestones.

The plan follows the core execution chain:

```text
Command -> Task -> Events -> Tool/Agent -> Approval -> Artifact -> History
```

The first build should make this chain stable before adding broader features.

## 1. Development Principles

- Build the execution loop before visual polish.
- Keep the runtime platform-neutral.
- Keep Swift/AppKit thin and macOS-specific.
- Prefer one working connector over many partial connectors.
- Prefer visible task events over hidden automation.
- Persist early; task history is part of the product.
- Add approvals before adding powerful tools.
- Treat research and agent orchestration as the two MVP workflows.

## 2. Milestone Overview

```text
M0: Project scaffold
M1: App shell and task storage
M2: Task runtime and live events
M3: Approval gate
M4: Agent connector
M5: Web research workflow
M6: macOS basics
M7: Settings and secrets
M8: Internal dogfood release
```

Recommended implementation order:

1. Scaffold.
2. Storage.
3. Task/event loop.
4. Approval loop.
5. Agent loop.
6. Research loop.
7. macOS integration.
8. Settings and hardening.

## 3. M0: Project Scaffold

### Goal

Create the initial Wails + Go + React/TypeScript project structure.

### Tasks

- Initialize Git repository if needed.
- Initialize Wails app.
- Configure React + TypeScript frontend.
- Add Tailwind CSS.
- Add basic linting and formatting.
- Add project directories.
- Add initial README.
- Add app startup smoke test.

### Suggested Structure

```text
crow/
├── apps/
│   └── desktop/
│       ├── frontend/
│       ├── backend/
│       ├── wails.json
│       └── go.mod
├── internal/
│   ├── runtime/
│   ├── storage/
│   ├── events/
│   ├── tasks/
│   ├── tools/
│   ├── agents/
│   ├── approvals/
│   ├── artifacts/
│   ├── platform/
│   └── settings/
├── native/
│   └── macos/
├── docs/
└── scripts/
```

### Acceptance Criteria

- App starts locally.
- Frontend renders a placeholder Crow shell.
- Go backend method can be called from frontend.
- Project has repeatable dev command.

### Exit Check

```text
Developer can run the desktop app and see a working placeholder UI.
```

## 4. M1: App Shell And Task Storage

### Goal

Create the basic product shell and persist tasks in SQLite.

### Tasks

- Add SQLite dependency.
- Implement database initialization.
- Implement migrations.
- Create `tasks` table.
- Create task repository.
- Add `CreateTask`, `ListTasks`, `GetTask` backend methods.
- Build main layout.
- Build command bar.
- Build task sidebar.
- Build empty states.

### Backend Scope

- `storage.DB`
- `storage.Migrate`
- `tasks.Repository`
- `tasks.Service`
- Wails bindings for task APIs

### Frontend Scope

- `AppShell`
- `CommandBar`
- `TaskSidebar`
- `TaskList`
- `TaskListItem`
- `EmptyState`

### Acceptance Criteria

- User can type a command.
- Submitting creates a task.
- Task appears in sidebar.
- Task persists after app restart.
- Empty state disappears once task exists.

### Exit Check

```text
Crow can create and remember tasks.
```

## 5. M2: Task Runtime And Live Events

### Goal

Make task execution observable through persisted and live events.

### Tasks

- Create `task_events` table.
- Implement event repository.
- Implement in-process event bus.
- Implement task state transitions.
- Add `StartTask`, `PauseTask`, `ResumeTask`, `CancelTask`.
- Build task detail view.
- Build task timeline.
- Broadcast runtime events to frontend.
- Persist events before broadcasting.
- Add mock executor that emits step events.

### Backend Scope

- `events.Bus`
- `events.Repository`
- `tasks.StateMachine`
- `runtime.Executor`
- Mock step executor

### Frontend Scope

- `TaskDetail`
- `TaskHeader`
- `TaskControls`
- `TaskTimeline`
- `TimelineItem`
- `StatusPill`

### Acceptance Criteria

- User can start a task.
- Timeline updates without manual refresh.
- Events persist after restart.
- User can cancel a running mock task.
- Failed mock task shows readable error.

### Exit Check

```text
Crow can show what it is doing while a task runs.
```

## 6. M3: Approval Gate

### Goal

Block risky actions and let the user approve or reject them.

### Tasks

- Create `approval_requests` table.
- Create `approval_decisions` table.
- Implement approval service.
- Implement risk levels.
- Add permission gate.
- Create mock risky tool.
- Add approval queue UI.
- Add approval card in task detail.
- Implement approve/reject backend methods.
- Resume task after approval.
- Fail task with `permission_rejected` after rejection.

### Backend Scope

- `approvals.Service`
- `approvals.Repository`
- `permissions.Policy`
- `permissions.Gate`
- Mock risky tool

### Frontend Scope

- `ApprovalQueue`
- `ApprovalCard`
- `RiskBadge`
- Approval badge in sidebar

### Acceptance Criteria

- Risky mock tool creates approval request.
- Task enters `waiting_approval`.
- Approval appears in queue and task detail.
- Approving resumes task.
- Rejecting fails task with clear reason.
- Approval decision persists after restart.

### Exit Check

```text
Crow can safely pause before sensitive actions.
```

## 7. M4: Agent Connector

### Goal

Connect Crow to at least one real external agent runtime.

### Tasks

- Create `agent_runs` table.
- Define `AgentConnector` interface.
- Implement connector registry.
- Implement first connector.
- Normalize connector events to Crow events.
- Stream agent status to timeline.
- Store agent run summary.
- Add agent status card.
- Add connector unavailable state.
- Add cancellation support if connector supports it.

### First Connector Options

Choose one:

- Existing agent runtime connector.
- Codex connector.
- Claude connector.

Recommendation:

> Start with the existing agent runtime if it already exposes a stable API or event stream.

### Backend Scope

- `agents.Connector`
- `agents.Registry`
- `agents.Service`
- First concrete connector

### Frontend Scope

- `AgentStatusCard`
- Agent timeline event rendering
- Connector missing error state

### Acceptance Criteria

- User can create an agent task.
- Agent run starts.
- Agent emits at least three visible events.
- Agent run completes with summary.
- Agent run failure is readable.
- Missing connector shows actionable settings prompt.

### Exit Check

```text
Crow can orchestrate one real AI agent from the desktop console.
```

## 8. M5: Web Research Workflow

### Goal

Generate a useful sourced Markdown report from a research command.

### Tasks

- Create `tool_runs` table.
- Create `artifacts` table.
- Implement tool registry.
- Implement `browser.search` or search provider tool.
- Implement `browser.extract` or page extraction tool.
- Implement `artifact.write_markdown`.
- Implement research service.
- Add model provider call for summarization.
- Add artifact service.
- Add source list UI.
- Add artifact card UI.
- Add open artifact action.

### Backend Scope

- `tools.Registry`
- `tools.Runner`
- `research.Service`
- `artifacts.Service`
- Search tool
- Extract tool
- Markdown artifact tool

### Frontend Scope

- `ResultSummary`
- `SourceList`
- `ArtifactCard`
- Research-specific timeline rendering

### Acceptance Criteria

- User can create a research task.
- Crow searches or retrieves candidate sources.
- Crow extracts at least three usable sources.
- Crow produces Markdown report.
- Source URLs are visible.
- Artifact opens from task detail.

### Exit Check

```text
Crow can complete a non-developer workflow with a reusable output.
```

## 9. M6: macOS Basics

### Goal

Make Crow feel like a desktop assistant rather than a web page in a window.

### Tasks

- Add menu bar icon.
- Add menu bar menu.
- Add global shortcut.
- Add notification on approval required.
- Add notification on task completed.
- Add notification click behavior.
- Add app focus behavior from shortcut.
- Add placeholder native platform adapter.

### Backend Scope

- `platform.Platform`
- `platform.MacOS`
- Wails/native integration

### Frontend Scope

- Runtime status indicator
- Shortcut status in settings

### Acceptance Criteria

- Menu bar icon appears.
- User can open Crow from menu bar.
- Global shortcut focuses command input.
- Approval required triggers notification.
- Clicking notification opens related task or approval.

### Exit Check

```text
Crow has the minimum native macOS presence needed for daily use.
```

## 10. M7: Settings And Secrets

### Goal

Let users configure model provider, connector, and local storage safely.

### Tasks

- Create `settings` table.
- Implement settings service.
- Implement macOS Keychain secret storage.
- Add model provider settings.
- Add agent connector settings.
- Add storage settings.
- Add permission policy summary.
- Add connection test methods.
- Hide saved secrets after entry.

### Backend Scope

- `settings.Service`
- `secrets.Store`
- `models.Provider`
- Connector test methods

### Frontend Scope

- `SettingsView`
- Model provider settings
- Agent connector settings
- Storage settings
- Permissions summary

### Acceptance Criteria

- User can save model provider config.
- API key is not stored in plaintext SQLite.
- User can test provider connection.
- User can configure first agent connector.
- Missing config creates actionable error state.

### Exit Check

```text
Crow can be configured without editing files or environment variables.
```

## 11. M8: Internal Dogfood Release

### Goal

Make the MVP usable for real internal tasks.

### Tasks

- Package macOS app.
- Add basic app icon placeholder.
- Add error boundary in frontend.
- Add log file output.
- Add crash-safe startup behavior.
- Add seed/demo tasks optional.
- Run manual test scenarios.
- Fix high-priority bugs.
- Write internal release notes.

### Manual Test Scenarios

- Create basic task.
- Start and cancel mock task.
- Run approval mock task and approve.
- Run approval mock task and reject.
- Run real agent task.
- Run research task.
- Restart app and confirm history remains.
- Remove model key and confirm error state.
- Trigger approval notification.

### Acceptance Criteria

- App can be installed and launched on macOS.
- Primary workflows work without developer intervention.
- Task history survives restart.
- Failures are understandable.
- No secrets are written to logs or SQLite.

### Exit Check

```text
One user can dogfood Crow for real agent and research tasks.
```

## 12. Engineering Backlog

### Backend

- Wails bindings.
- SQLite migrations.
- Task repository.
- Event repository.
- Approval repository.
- Tool run repository.
- Agent run repository.
- Artifact repository.
- Task state machine.
- Event bus.
- Permission gate.
- Tool registry.
- Agent registry.
- Research service.
- Artifact writer.
- Settings service.
- Keychain secret store.
- Platform adapter.

### Frontend

- App shell.
- Command bar.
- Task sidebar.
- Task list item.
- Task detail.
- Task controls.
- Timeline item.
- Approval queue.
- Approval card.
- Risk badge.
- Agent status card.
- Result summary.
- Source list.
- Artifact card.
- Settings view.
- Empty states.
- Error states.

### Native macOS

- Menu bar item.
- Global shortcut.
- Native notifications.
- Keychain bridge.
- App focus behavior.

### Tests

- Task state machine tests.
- Event persistence tests.
- Approval flow tests.
- Tool registry tests.
- Mock agent connector tests.
- Research service tests with mocked sources.
- Settings and secrets tests.

## 13. Cut Lines

If scope grows, cut in this order:

1. Voice input.
2. Floating island panel.
3. Workflow templates.
4. Retry failed step.
5. Raw log viewer.
6. Connector setup wizard.
7. Active app detection.
8. Selected text capture.
9. Advanced permission editing.
10. Multiple agent connectors.

Do not cut:

- Task persistence.
- Event timeline.
- Approval gate.
- One real agent connector.
- Research artifact output.

## 14. First Internal Release Definition

The first internal release is ready when these three workflows work end to end:

### Workflow 1: Command To Task

```text
Open Crow
Type a task
Task appears
Task runs
Timeline updates
Task completes or fails clearly
History persists after restart
```

### Workflow 2: Agent Orchestration

```text
Ask Crow to run an agent task
Agent starts
Agent events appear
Agent completes
Crow shows final summary
```

### Workflow 3: Web Research

```text
Ask Crow to research a topic
Crow searches and extracts sources
Crow creates Markdown report
User opens report
Sources are visible
```

## 15. Suggested Sprint Plan

### Sprint 1: Foundation

Target:

- M0
- M1
- Start M2

Outcome:

```text
App runs, tasks persist, basic UI exists.
```

### Sprint 2: Runtime

Target:

- Finish M2
- M3

Outcome:

```text
Tasks run with live events and approval blocking.
```

### Sprint 3: Agent

Target:

- M4
- Start M7 connector settings

Outcome:

```text
Crow can run one real agent task.
```

### Sprint 4: Research

Target:

- M5
- Artifact handling

Outcome:

```text
Crow can produce sourced Markdown reports.
```

### Sprint 5: Desktop Fit

Target:

- M6
- M7
- Hardening

Outcome:

```text
Crow feels like a macOS desktop app and is dogfoodable.
```

## 16. Readiness Checklist Before Coding

Before scaffold begins, decide:

- Wails version.
- Frontend package manager.
- CSS approach.
- SQLite migration library.
- First agent connector.
- Search provider.
- Model provider strategy.
- Default global shortcut.
- App data directory.

Recommended defaults:

```text
Wails: current stable v2 unless v3 is explicitly chosen
Frontend: React + TypeScript
Package manager: pnpm
CSS: Tailwind CSS
SQLite: modernc.org/sqlite or mattn/go-sqlite3
Migrations: golang-migrate or embedded SQL migrations
First connector: existing agent runtime
Search: provider API first, Playwright/browser fallback later
Models: BYOK first
Shortcut: Option + Space
Data directory: ~/Library/Application Support/Crow/
```

## 17. Next Step

After this plan, the next practical step is:

```text
Scaffold the Wails app and implement M0/M1.
```

If design fidelity is needed before coding, create a low-fidelity wireframe first. Otherwise start with the app shell and task persistence.
