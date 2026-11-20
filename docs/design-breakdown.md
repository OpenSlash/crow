# Crow MVP Design Breakdown

This document breaks the generated Crow MVP design reference into implementable product areas, frontend components, backend dependencies, and milestone ownership.

Design reference:

```text
output/imagegen/crow-mvp-console.png
```

The design shows the MVP command center:

```text
Command input -> Task list -> Task detail -> Timeline -> Approval -> Agent status -> Research result -> Artifact -> Sources
```

## 1. Screen-Level Breakdown

The generated screen has seven functional regions:

```text
1. macOS app chrome and menu bar presence
2. Top command bar
3. Left task sidebar
4. Task header and metadata
5. Execution timeline
6. Active execution cards
7. Result and artifact area
```

Implementation priority:

```text
P0: command bar, task sidebar, task detail, timeline
P1: approval card, agent status card, artifact card
P2: macOS menu bar, notifications, settings polish
P3: floating panel and voice controls
```

## 2. Region 1: macOS App Chrome

### What The Design Shows

- macOS-style application window.
- App identity: Crow name and small crow mark.
- Menu bar hint.
- User/avatar control.
- New Task button.

### MVP Function

Make Crow feel like a desktop app, not a browser page.

### Frontend Components

```text
AppShell
AppHeader
RuntimeStatus
NewTaskButton
UserMenu optional
```

### Backend Dependencies

```text
platform.Platform
settings.Service
runtime health state
```

### MVP Acceptance

- App opens to task console.
- Header shows Crow identity.
- New Task focuses command input.
- Settings entry is reachable.

### Defer

- Real user account menu.
- Polished brand icon.
- Floating island.

## 3. Region 2: Top Command Bar

### What The Design Shows

- Search/command input.
- Placeholder: "Ask Crow to research, run an agent, or organize a task..."
- Keyboard shortcut hint.

### MVP Function

Primary task creation entry.

### Frontend Components

```text
CommandBar
CommandInput
CommandModeSelector optional
SubmitButton
ShortcutHint
```

### Backend APIs

```go
CreateTask(input CreateTaskInput) (TaskDTO, error)
StartTask(taskID string) error
```

### Data Dependencies

```text
tasks
task_events
settings
```

### States

```text
idle
typing
submitting
created
failed_to_create
unsupported_command
```

### MVP Acceptance

- User can type command and submit.
- Task is created within one second locally.
- New task appears in sidebar.
- Task detail opens automatically.
- Task starts automatically for supported low-risk flows.

### Defer

- Voice button.
- Command templates.
- Rich mentions for files/pages.

## 4. Region 3: Left Task Sidebar

### What The Design Shows

- Status filters: All, Running, Waiting, Completed, Failed.
- Task rows with title, status, and time.
- Active task selected.
- Bottom actions: Filters, Settings.

### MVP Function

Task history and navigation.

### Frontend Components

```text
TaskSidebar
TaskFilters
TaskList
TaskListItem
StatusPill
ApprovalBadge
SidebarFooter
```

### Backend APIs

```go
ListTasks() ([]TaskDTO, error)
GetTask(taskID string) (TaskDetailDTO, error)
ListPendingApprovals() ([]ApprovalRequestDTO, error)
```

### Data Dependencies

```text
tasks
approval_requests
```

### States

```text
empty
loading
loaded
filtered_empty
error
```

### MVP Acceptance

- Sidebar lists persisted tasks.
- Selecting task opens task detail.
- Filters work locally.
- Waiting approval tasks are visually distinct.
- Failed tasks show readable status.

### Defer

- Search within task history.
- Advanced filters.
- Bulk actions.

## 5. Region 4: Task Header And Metadata

### What The Design Shows

- Active task title: "Research AI desktop assistants".
- Status badge: Waiting Approval.
- Priority pill.
- Actions menu.
- Metadata row: started time, task ID.

### MVP Function

Show what task is selected and what state it is in.

### Frontend Components

```text
TaskHeader
TaskMetadata
TaskControls
StatusPill
TaskActionsMenu
```

### Backend APIs

```go
GetTask(taskID string) (TaskDetailDTO, error)
PauseTask(taskID string) error
ResumeTask(taskID string) error
CancelTask(taskID string) error
```

### Data Dependencies

```text
tasks
task_steps
task_events
```

### Controls By Status

```text
pending: Start, Cancel
running: Pause, Cancel
waiting_approval: Cancel
paused: Resume, Cancel
completed: Open artifact
failed: Retry optional after MVP
cancelled: no primary control
```

### MVP Acceptance

- Header reflects current task status.
- Cancel works for running/waiting tasks.
- Pause/resume works for mock/runtime tasks.
- Task ID is visible or copyable.

### Defer

- Priority editing.
- Actions dropdown complexity.
- Task star/favorite behavior.

## 6. Region 5: Execution Timeline

### What The Design Shows

- Horizontal progress timeline with stages:
  - search
  - source extraction
  - summarization
  - approval
  - artifact creation
  - completion

### MVP Function

Make execution observable and trustworthy.

### Frontend Components

```text
TaskTimeline
TimelineStep
TimelineItem
TimelineConnector
EventDetails
```

### Backend APIs

```go
ListTaskEvents(taskID string) ([]TaskEventDTO, error)
SubscribeTaskEvents() event stream
```

### Data Dependencies

```text
task_events
task_steps
tool_runs
agent_runs
approval_requests
artifacts
```

### Required Event Types

```text
task.created
task.started
step.started
step.completed
tool.called
tool.completed
approval.required
approval.approved
approval.rejected
agent.started
agent.completed
artifact.created
task.completed
task.failed
```

### MVP Acceptance

- Timeline updates live.
- Events persist after restart.
- Tool calls are visible.
- Approval state blocks progress visually.
- Failed event shows error message.

### Important Implementation Note

The generated design uses a compact horizontal timeline. The MVP can start with a vertical timeline because it is easier to render for long event lists. A horizontal stage tracker can be added above the vertical event feed later.

Recommended MVP:

```text
Stage tracker: compact summary
Event feed: vertical detailed timeline
```

## 7. Region 6: Approval Card

### What The Design Shows

- "Approval Required"
- "Level 2 - Reversible"
- Explanation of proposed action.
- Approve & Continue button.
- Hold button.

### MVP Function

Block sensitive execution until user decides.

### Frontend Components

```text
ApprovalCard
RiskBadge
ApprovalPreview
ApproveButton
RejectButton
ApprovalComment optional
```

### Backend APIs

```go
ListPendingApprovals() ([]ApprovalRequestDTO, error)
Approve(approvalID string, comment string) error
Reject(approvalID string, comment string) error
```

### Data Dependencies

```text
approval_requests
approval_decisions
task_events
```

### MVP Acceptance

- Approval card appears when task waits.
- Risk level is clear.
- Proposed action is readable.
- Approve resumes task.
- Reject fails or cancels blocked action.
- Decision is persisted.

### Design Adjustment

The generated image says "Hold". MVP should use:

```text
Reject
```

or:

```text
Reject / Stop Task
```

Reason: user needs a clear safety action. "Hold" is ambiguous for MVP.

## 8. Region 7: Agent Status Card

### What The Design Shows

- "Codex: Running checks"
- Short status text.
- Progress bar.
- Details row.

### MVP Function

Show external agent activity inside Crow.

### Frontend Components

```text
AgentStatusCard
AgentProgress
AgentLogPreview
AgentDetailsToggle
ConnectorStatus
```

### Backend APIs

```go
ListAgentConnectors() ([]AgentConnectorDTO, error)
TestAgentConnector(name string) error
CancelAgentRun(runID string) error
```

Agent execution happens through task APIs and event stream.

### Data Dependencies

```text
agent_runs
task_events
settings
```

### MVP Acceptance

- One real connector can start a run.
- Agent status appears in task timeline/detail.
- Agent emits readable events.
- Agent completion summary is stored.
- Connector missing state is actionable.

### Defer

- Real progress percentage unless connector supports it.
- Multiple simultaneous agent cards.
- Full raw log viewer.

## 9. Region 8: Research Result Panel

### What The Design Shows

- "Research Report"
- Key findings.
- Open Markdown button.
- Report generated from sources.

### MVP Function

Show the useful output of web research.

### Frontend Components

```text
ResultSummary
ResearchReportPreview
KeyFindingsList
OpenArtifactButton
```

### Backend APIs

```go
OpenArtifact(artifactID string) error
ListArtifacts(taskID string) ([]ArtifactDTO, error)
```

### Data Dependencies

```text
artifacts
tool_runs
task_events
```

### MVP Acceptance

- Completed research task shows summary.
- Key findings are readable.
- Markdown artifact opens from UI.
- Research source count is visible.

### Defer

- In-app Markdown editor.
- Export to Notion/Google Docs.
- Rich citation formatting.

## 10. Region 9: Artifact Card

### What The Design Shows

- "Markdown Artifact"
- File name.
- File size.
- Open Markdown button.

### MVP Function

Make generated outputs reusable.

### Frontend Components

```text
ArtifactCard
ArtifactMeta
OpenArtifactButton
RevealInFinderButton optional
```

### Backend APIs

```go
ListArtifacts(taskID string) ([]ArtifactDTO, error)
OpenArtifact(artifactID string) error
RevealArtifact(artifactID string) error optional
```

### Data Dependencies

```text
artifacts
```

### MVP Acceptance

- Artifact metadata is persisted.
- Open button launches default app.
- Missing file shows readable error.

## 11. Region 10: Sources Card

### What The Design Shows

- "Sources"
- Top source list.
- View all count.
- External-link icons.

### MVP Function

Make research output inspectable and trustworthy.

### Frontend Components

```text
SourceList
SourceListItem
SourceDomain
SourceLink
```

### Backend Dependencies

Sources can be stored in:

```text
tool_runs.output_json
artifacts metadata
or a future research_sources table
```

MVP recommendation:

> Store source metadata in artifact metadata and task event payloads first. Add `research_sources` table only when source operations become complex.

### MVP Acceptance

- At least three source URLs are visible.
- User can open source URL.
- Research report includes source list.

## 12. Data Mapping

### UI To Database

```text
CommandBar -> tasks
TaskSidebar -> tasks + approval_requests
TaskHeader -> tasks
Timeline -> task_events + task_steps
ApprovalCard -> approval_requests + approval_decisions
AgentStatusCard -> agent_runs + task_events
ResearchReportPreview -> artifacts + task_events
ArtifactCard -> artifacts
SourceList -> artifact metadata / tool_runs output
```

### UI To Backend Service

```text
CommandBar -> tasks.Service
TaskSidebar -> tasks.Service
Timeline -> events.Bus + events.Repository
ApprovalCard -> approvals.Service
AgentStatusCard -> agents.Service
ResearchReportPreview -> research.Service
ArtifactCard -> artifacts.Service
Settings -> settings.Service + secrets.Store
```

## 13. Frontend Component Tree

Recommended MVP component structure:

```text
AppShell
├── AppHeader
│   ├── BrandMark
│   ├── RuntimeStatus
│   └── SettingsButton
├── CommandBar
├── Workspace
│   ├── TaskSidebar
│   │   ├── TaskFilters
│   │   └── TaskList
│   │       └── TaskListItem
│   └── TaskDetail
│       ├── TaskHeader
│       ├── StageTracker
│       ├── ActiveCards
│       │   ├── ApprovalCard
│       │   └── AgentStatusCard
│       ├── TaskTimeline
│       │   └── TimelineItem
│       └── ResultArea
│           ├── ResearchReportPreview
│           ├── ArtifactCard
│           └── SourceList
└── SettingsDialog
```

## 14. Backend Implementation Order From Design

The design can be implemented in this order:

```text
1. App shell
2. CommandBar -> CreateTask
3. TaskSidebar -> ListTasks
4. TaskDetail -> GetTask
5. TaskTimeline -> task_events
6. Mock executor -> live events
7. ApprovalCard -> approval flow
8. AgentStatusCard -> first connector
9. ResearchReportPreview -> research workflow
10. ArtifactCard -> artifact service
11. SourceList -> source metadata
12. macOS menu bar/shortcut/notification
```

## 15. Design Deviations For MVP

The generated design is a target reference, not a strict implementation spec.

Recommended deviations:

- Use vertical event feed in addition to compact stage tracker.
- Replace "Hold" with "Reject" or "Stop Task".
- Do not implement real priority in MVP.
- Do not implement account avatar in MVP.
- Do not show precise agent percentage unless available.
- Keep task actions menu minimal.
- Use placeholder crow mark until brand work is ready.

## 16. P0 Build Scope

P0 is the minimum UI needed to start coding product value.

Must build:

- App shell.
- Command bar.
- Task sidebar.
- Task detail.
- Timeline event feed.
- Approval card.
- Basic result area.

Can fake initially:

- Agent status card.
- Research output.
- Source list.
- Artifact card.

Must not fake for dogfood:

- Task persistence.
- Event persistence.
- Approval decision persistence.
- Opening artifact.
- One real agent connector.

## 17. Acceptance Checklist Against Design

The implementation matches the design intent when:

- The first screen is a task console.
- A command creates a task.
- Running work is visible in the timeline.
- Waiting approvals are obvious.
- Agent status is visible without opening another tool.
- Research output has sources.
- Generated artifact is easy to open.
- The UI does not feel like a chat transcript.

The implementation fails the design intent if:

- Main surface is only a chat box.
- Task progress is a spinner with no timeline.
- Approvals appear only in logs.
- Research output lacks sources.
- Agent work is hidden outside Crow.
- Generated reports are not accessible as files.
