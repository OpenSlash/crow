# Crow MVP System Design

This document turns the MVP PRD into an engineering design for the first implementation of Crow.

Scope:

- Wails + Go desktop app.
- React/TypeScript task console.
- Embedded Go runtime for MVP.
- SQLite persistence.
- macOS-first platform adapter.
- One agent connector.
- Web research workflow.
- Approval gate.

## 1. Design Goals

The MVP system must:

- Create tasks from user commands.
- Execute tasks through tools or agent connectors.
- Emit live task events.
- Persist task state and history.
- Block risky actions through approval requests.
- Save output artifacts.
- Keep core runtime platform-neutral.

The MVP system should avoid:

- Daemon complexity.
- Multi-user concerns.
- Plugin marketplace.
- Team permissions.
- Full workflow automation.
- Deep native platform coupling.

## 2. Runtime Architecture

MVP runs as a single desktop app process.

```text
Crow.app
├── Wails shell
│   ├── React frontend
│   └── Go bindings
│
├── Go runtime
│   ├── Task service
│   ├── Event bus
│   ├── Tool registry
│   ├── Permission gate
│   ├── Agent service
│   ├── Research service
│   ├── Artifact service
│   └── Storage service
│
├── SQLite database
│
└── macOS platform adapter
    ├── Menu bar
    ├── Global shortcut
    ├── Notification
    └── Keychain
```

Future daemon split:

```text
Crow.app -> local API -> crowd daemon -> SQLite/tools/agents
```

The MVP code should keep services independent enough to move into `crowd` later.

## 3. Module Boundaries

### frontend

Responsibilities:

- Render command input.
- Render task list.
- Render task detail timeline.
- Render approval queue.
- Render research artifacts.
- Render settings.
- Subscribe to runtime events.
- Call Wails-bound Go methods.

The frontend must not implement task state transitions or permission policy.

### app

Responsibilities:

- Wails lifecycle.
- Bind Go methods to frontend.
- Initialize runtime services.
- Initialize platform adapter.
- Wire event bus to UI events.

### runtime/task

Responsibilities:

- Create tasks.
- Start tasks.
- Pause/resume/cancel tasks.
- Manage task status.
- Append task events.
- Coordinate tool, agent, and research execution.

### runtime/events

Responsibilities:

- Publish task events.
- Persist events.
- Broadcast events to frontend subscribers.
- Replay events for task detail.

### runtime/permissions

Responsibilities:

- Classify action risk.
- Create approval requests.
- Block execution until approval.
- Store approval decisions.
- Resume or reject blocked actions.

### runtime/tools

Responsibilities:

- Register tools.
- Validate tool inputs.
- Execute tools.
- Emit tool events.
- Route risky tool calls through Permission Gate.

### runtime/agents

Responsibilities:

- Configure agent connectors.
- Start agent runs.
- Stream agent events.
- Cancel agent runs.
- Normalize connector-specific events into Crow events.

### runtime/research

Responsibilities:

- Plan research steps.
- Generate search queries.
- Search web.
- Extract pages.
- Summarize findings.
- Create Markdown artifacts.

### runtime/artifacts

Responsibilities:

- Write artifacts to local storage.
- Store artifact metadata.
- Open artifacts from task detail.

### runtime/storage

Responsibilities:

- SQLite connection lifecycle.
- Schema migrations.
- Repository methods.
- Transaction helpers.

### runtime/platform

Responsibilities:

- Provide platform-neutral interface.
- macOS implementation for shortcut, menu bar, notification, keychain.
- Future Windows/Linux implementations.

## 4. Task State Machine

Task statuses:

```text
pending
running
waiting_approval
paused
completed
failed
cancelled
```

Allowed transitions:

```text
pending -> running
pending -> cancelled

running -> waiting_approval
running -> paused
running -> completed
running -> failed
running -> cancelled

waiting_approval -> running
waiting_approval -> failed
waiting_approval -> cancelled

paused -> running
paused -> cancelled

failed -> running        # retry, optional after MVP
completed -> running     # rerun, optional after MVP
```

MVP required transitions:

- `pending -> running`
- `running -> waiting_approval`
- `waiting_approval -> running`
- `waiting_approval -> cancelled`
- `running -> completed`
- `running -> failed`
- `running -> cancelled`
- `running -> paused`
- `paused -> running`

Rules:

- A task can have many events.
- A task can have many steps.
- A task can have many tool runs.
- A task can have many approval requests.
- A task can have many artifacts.
- Only one active blocking approval should exist for a task in MVP.

## 5. Event Model

Task events are the source of truth for visible execution history.

Event requirements:

- Persist every event.
- Broadcast events to the frontend.
- Use stable event types.
- Keep event payload JSON serializable.
- Avoid storing large raw outputs in event payloads.
- Store large outputs as artifacts or tool run records.

Event type list:

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

artifact.created
```

Event structure:

```go
type TaskEvent struct {
    ID        string         `json:"id"`
    TaskID    string         `json:"taskId"`
    StepID    string         `json:"stepId,omitempty"`
    Type      string         `json:"type"`
    Title     string         `json:"title,omitempty"`
    Message   string         `json:"message,omitempty"`
    Payload   map[string]any `json:"payload,omitempty"`
    CreatedAt time.Time      `json:"createdAt"`
}
```

## 6. Database Schema

SQLite is the MVP database.

### tasks

```sql
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    user_input TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'general',
    status TEXT NOT NULL,
    result_summary TEXT,
    error_message TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT
);
```

Indexes:

```sql
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_created_at ON tasks(created_at);
```

### task_steps

```sql
CREATE TABLE task_steps (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    title TEXT NOT NULL,
    status TEXT NOT NULL,
    order_index INTEGER NOT NULL,
    started_at TEXT,
    completed_at TEXT,
    error_message TEXT,
    FOREIGN KEY(task_id) REFERENCES tasks(id)
);
```

Indexes:

```sql
CREATE INDEX idx_task_steps_task_id ON task_steps(task_id);
```

### task_events

```sql
CREATE TABLE task_events (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    step_id TEXT,
    type TEXT NOT NULL,
    title TEXT,
    message TEXT,
    payload_json TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY(task_id) REFERENCES tasks(id)
);
```

Indexes:

```sql
CREATE INDEX idx_task_events_task_id_created_at ON task_events(task_id, created_at);
```

### approval_requests

```sql
CREATE TABLE approval_requests (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    risk_level INTEGER NOT NULL,
    proposed_action_json TEXT NOT NULL,
    preview TEXT,
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    decided_at TEXT,
    expires_at TEXT,
    FOREIGN KEY(task_id) REFERENCES tasks(id)
);
```

Statuses:

```text
pending
approved
rejected
expired
cancelled
```

Indexes:

```sql
CREATE INDEX idx_approval_requests_task_id ON approval_requests(task_id);
CREATE INDEX idx_approval_requests_status ON approval_requests(status);
```

### approval_decisions

```sql
CREATE TABLE approval_decisions (
    id TEXT PRIMARY KEY,
    approval_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    approved INTEGER NOT NULL,
    comment TEXT,
    decided_at TEXT NOT NULL,
    FOREIGN KEY(approval_id) REFERENCES approval_requests(id),
    FOREIGN KEY(task_id) REFERENCES tasks(id)
);
```

### tool_runs

```sql
CREATE TABLE tool_runs (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    step_id TEXT,
    tool_name TEXT NOT NULL,
    risk_level INTEGER NOT NULL,
    input_json TEXT,
    output_json TEXT,
    status TEXT NOT NULL,
    error_message TEXT,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    FOREIGN KEY(task_id) REFERENCES tasks(id)
);
```

Indexes:

```sql
CREATE INDEX idx_tool_runs_task_id ON tool_runs(task_id);
```

### agent_runs

```sql
CREATE TABLE agent_runs (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    connector_name TEXT NOT NULL,
    external_run_id TEXT,
    status TEXT NOT NULL,
    input_json TEXT,
    summary TEXT,
    error_message TEXT,
    started_at TEXT NOT NULL,
    completed_at TEXT,
    FOREIGN KEY(task_id) REFERENCES tasks(id)
);
```

Indexes:

```sql
CREATE INDEX idx_agent_runs_task_id ON agent_runs(task_id);
```

### artifacts

```sql
CREATE TABLE artifacts (
    id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL,
    type TEXT NOT NULL,
    title TEXT NOT NULL,
    path TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    size_bytes INTEGER,
    created_at TEXT NOT NULL,
    FOREIGN KEY(task_id) REFERENCES tasks(id)
);
```

Indexes:

```sql
CREATE INDEX idx_artifacts_task_id ON artifacts(task_id);
```

### settings

```sql
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

### memories

Memory is optional in MVP. If included:

```sql
CREATE TABLE memories (
    id TEXT PRIMARY KEY,
    namespace TEXT NOT NULL,
    content TEXT NOT NULL,
    metadata_json TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

## 7. Storage Paths

Default app data path:

```text
~/Library/Application Support/Crow/
```

Suggested layout:

```text
~/Library/Application Support/Crow/
├── crow.db
├── artifacts/
│   └── {task_id}/
│       └── report.md
├── logs/
└── temp/
```

Secrets:

- Store API keys in macOS Keychain.
- Store only key references in SQLite.

## 8. Runtime APIs

These methods should be exposed to the Wails frontend.

### Task APIs

```go
CreateTask(input CreateTaskInput) (TaskDTO, error)
StartTask(taskID string) error
PauseTask(taskID string) error
ResumeTask(taskID string) error
CancelTask(taskID string) error
ListTasks() ([]TaskDTO, error)
GetTask(taskID string) (TaskDetailDTO, error)
ListTaskEvents(taskID string) ([]TaskEventDTO, error)
```

### Approval APIs

```go
ListPendingApprovals() ([]ApprovalRequestDTO, error)
Approve(approvalID string, comment string) error
Reject(approvalID string, comment string) error
```

### Artifact APIs

```go
ListArtifacts(taskID string) ([]ArtifactDTO, error)
OpenArtifact(artifactID string) error
```

### Settings APIs

```go
GetSettings() (SettingsDTO, error)
UpdateSettings(input UpdateSettingsInput) error
SetSecret(key string, value string) error
HasSecret(key string) (bool, error)
```

### Agent APIs

```go
ListAgentConnectors() ([]AgentConnectorDTO, error)
TestAgentConnector(name string) error
```

## 9. Task Execution Flow

### Create task

```text
Frontend calls CreateTask
Task service stores task as pending
Task service appends task.created event
Event bus publishes task.created
Frontend updates task list
```

### Start general task

```text
Frontend calls StartTask
Task service sets status running
Task service appends task.started
Planner classifies task kind
Task service routes to executor
Executor emits steps and tool events
Task completes, fails, or waits for approval
```

### Approval-required tool call

```text
Executor calls ToolRunner
ToolRunner checks risk level
Permission Gate creates approval request
Task status becomes waiting_approval
approval.required event is emitted
Frontend shows approval request
User approves or rejects
Permission Gate records decision
Task resumes or stops
```

### Research task

```text
Task starts
Research service creates search step
Search tool runs
Research service selects sources
Extract tool runs per source
Model summarizes findings
Artifact service writes Markdown
artifact.created event emitted
Task completes with summary
```

### Agent task

```text
Task starts
Agent service selects connector
Connector starts external agent run
Agent events stream into Crow event bus
Approval requests are normalized if needed
Agent returns summary
Task completes or fails
```

## 10. Planner MVP

The MVP planner can be simple and deterministic.

Classification rules:

- If command mentions "research", "调研", "查一下", "compare", or "sources", create research task.
- If command mentions "Codex", "Claude", "agent", "代理", or a configured connector name, create agent task.
- Otherwise create general task and ask user to choose a workflow or show unsupported state.

Later, replace or supplement with model-based planning.

MVP task kinds:

```text
research
agent
general
```

## 11. Tool Execution

Tool interface:

```go
type Tool interface {
    Name() string
    Description() string
    RiskLevel() RiskLevel
    InputSchema() any
    Run(ctx context.Context, input any) (ToolResult, error)
}

type ToolResult struct {
    Output   any
    Summary  string
    Artifact *ArtifactRef
}
```

Initial tools:

```text
browser.search
browser.extract
artifact.write_markdown
agent.run
```

Optional MVP tools:

```text
file.read
file.write
browser.open
```

Tool runner responsibilities:

- Create `tool_runs` record.
- Emit `tool.called`.
- Run permission check.
- Execute tool.
- Store output or artifact reference.
- Emit `tool.completed` or `tool.failed`.

## 12. Agent Connector Design

Agent connector interface:

```go
type AgentConnector interface {
    Name() string
    DisplayName() string
    IsConfigured(ctx context.Context) bool
    Start(ctx context.Context, req AgentTaskRequest) (AgentRunRef, error)
    Events(ctx context.Context, runID string) (<-chan AgentEvent, error)
    Cancel(ctx context.Context, runID string) error
}
```

Agent event structure:

```go
type AgentEvent struct {
    Type      string
    Message   string
    Payload   map[string]any
    CreatedAt time.Time
}
```

Connector rules:

- Connector-specific event names must be mapped to Crow event types.
- Connector logs should be summarized when noisy.
- Connector failures must become readable task failures.
- Unsupported cancel should return a typed error and show clear UI.

## 13. Research Workflow Design

MVP research pipeline:

```text
Input goal
Generate 2-4 search queries
Run search
Keep top 5-8 candidate sources
Extract readable text from 3-5 sources
Summarize source notes
Synthesize final report
Write Markdown artifact
Complete task
```

Report format:

```markdown
# Research Report: {topic}

## Summary

## Key Findings

## Source Notes

## Open Questions

## Sources
```

Research constraints:

- Always include URLs.
- Mark uncertainty when sources conflict.
- Avoid claiming completeness.
- Do not quote long passages.
- Store extracted source text as tool output only if small; otherwise store artifact or summary.

## 14. Frontend Views

### App Shell

Layout:

```text
┌──────────────────────────────────────────────┐
│ Command input                                │
├───────────────┬──────────────────────────────┤
│ Task list     │ Task detail                  │
│               │ Timeline                     │
│               │ Approvals / result / files   │
└───────────────┴──────────────────────────────┘
```

### Task List

Shows:

- Title
- Status
- Created time
- Small status indicator
- Current waiting approval badge

### Task Detail

Shows:

- Header with title and status.
- Action buttons: start, pause, resume, cancel.
- Timeline.
- Approval card if waiting.
- Result summary.
- Artifact links.

### Approval Queue

Shows:

- Pending approvals across tasks.
- Risk level.
- Proposed action.
- Preview.
- Approve/reject controls.

### Settings

Shows:

- Model provider configuration.
- Agent connector configuration.
- Storage path.
- Permission policy summary.
- Global shortcut status.

## 15. macOS Platform Adapter

MVP platform capabilities:

- Menu bar icon.
- Global shortcut.
- Native notification for approval required.
- Keychain get/set for secrets.

Optional V1.1:

- Floating panel.
- Active app detection.
- Selected text capture.
- Accessibility permission flow.

Platform interface:

```go
type Platform interface {
    RegisterGlobalShortcut(ctx context.Context, shortcut string) error
    ShowNotification(ctx context.Context, n Notification) error
    SetSecret(ctx context.Context, key string, value string) error
    GetSecret(ctx context.Context, key string) (string, error)
    HasSecret(ctx context.Context, key string) (bool, error)
}
```

Swift/AppKit helper should remain thin and platform-specific.

## 16. Error Handling

Error types:

```text
validation_error
permission_required
permission_rejected
tool_error
agent_error
model_error
network_error
storage_error
unsupported_task
cancelled
```

Rules:

- Every failed task must show a readable error.
- Tool errors should include tool name.
- Agent errors should include connector name.
- Internal stack traces should be written to logs, not shown as user-facing text.
- User-facing errors should suggest the next useful action where possible.

## 17. Logging

MVP logs:

- App startup/shutdown.
- Task lifecycle.
- Tool runs.
- Agent runs.
- Approval decisions.
- Storage errors.
- Model provider errors.

Do not log:

- API keys.
- Full email contents.
- Secrets.
- Sensitive form values.

Log storage:

```text
~/Library/Application Support/Crow/logs/
```

## 18. Testing Strategy

Unit tests:

- Task state transitions.
- Permission policy.
- Tool registry.
- Event persistence.
- Planner classification.

Integration tests:

- Create task and persist events.
- Approval blocks and resumes execution.
- Research task writes artifact.
- Agent connector mock streams events.

Manual test scenarios:

- Create and complete research task.
- Create agent task.
- Reject approval.
- Cancel running task.
- Restart app and verify task history remains.
- Missing API key shows actionable error.

## 19. MVP Milestones

### Milestone 1: App And Storage

- Wails app starts.
- React shell renders.
- SQLite initializes.
- Task can be created and listed.

### Milestone 2: Runtime Events

- Task engine runs simple tasks.
- Events persist.
- Timeline updates live.

### Milestone 3: Approval Gate

- Risky mock tool creates approval request.
- UI approves/rejects.
- Task resumes or cancels.

### Milestone 4: Agent Connector

- One connector works end to end.
- Agent events stream into task timeline.
- Final summary persists.

### Milestone 5: Research Workflow

- Search/extract/summarize/write report.
- Markdown artifact saved and linked.

### Milestone 6: macOS Basics

- Menu bar icon.
- Global shortcut.
- Approval notification.
- Keychain secret storage.

## 20. Implementation Order

Recommended order:

1. Create Wails app.
2. Add React shell.
3. Add SQLite and migrations.
4. Implement Task repository.
5. Implement Event repository and event bus.
6. Implement Task service.
7. Implement task list and task detail UI.
8. Implement Approval service and UI.
9. Implement Tool registry and mock risky tool.
10. Implement one Agent connector.
11. Implement Research service.
12. Implement Artifact service.
13. Add macOS shortcut and menu bar.
14. Add Keychain secret storage.
15. Dogfood with real tasks.

## 21. Key Open Questions

- Which Wails version should be used for the first scaffold?
- Which frontend state library should be used?
- Which SQLite migration library should be used?
- Which search provider should power web research?
- Should Playwright be bundled or installed separately?
- Which agent connector is first?
- Should Codex and Claude be separate connectors or routed through the existing agent runtime?
- Should the floating panel be deferred to V1.1?
- Should task execution be automatic after creation or require user pressing Start?

## 22. Final Engineering Boundary

The MVP should produce a small but durable foundation:

```text
Command -> Task -> Events -> Tool/Agent -> Approval -> Artifact -> History
```

If this chain is stable, Crow can grow into voice, email, memory, browser context, and full desktop orchestration without rewriting the core.
