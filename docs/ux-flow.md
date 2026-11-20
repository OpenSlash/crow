# Crow MVP UX Flow

This document defines the MVP user experience for Crow's desktop command center.

Scope:

- Main window.
- Command entry.
- Task list.
- Task detail timeline.
- Approval queue.
- Research result view.
- Agent run view.
- Settings.
- macOS menu bar and notification surface.

The MVP UX principle is:

> Crow should feel like an execution console, not a chat app.

## 1. UX Goals

The MVP experience must make users confident that:

- Crow understood the task.
- Crow is doing visible work.
- Crow will stop before sensitive actions.
- Crow can be interrupted.
- Crow produces reusable results.
- Crow keeps history.

The UI should emphasize:

- Task state.
- Execution timeline.
- Current step.
- Pending approval.
- Final artifact.

The UI should avoid:

- Chat-only layout.
- Hidden background execution.
- Decorative dashboards with low task value.
- Overly complex workflow builders in MVP.
- Heavy native floating UI before the main task console works.

## 2. Information Architecture

MVP navigation:

```text
Crow
├── Command
├── Tasks
├── Approvals
├── Artifacts
└── Settings
```

Primary surface:

```text
Main Window
├── Left Sidebar
│   ├── Task list
│   ├── Status filters
│   └── Approval badge
│
├── Main Panel
│   ├── Command input
│   ├── Task detail
│   ├── Timeline
│   ├── Approval cards
│   └── Result/artifacts
│
└── Right Inspector optional after MVP
    ├── Sources
    ├── Tool runs
    └── Metadata
```

MVP should use a two-column layout first:

```text
┌────────────────────────────────────────────────────┐
│ Command input                                      │
├──────────────────┬─────────────────────────────────┤
│ Task list         │ Task detail                     │
│                   │ Timeline / approval / result    │
└──────────────────┴─────────────────────────────────┘
```

## 3. Main Window

### Layout

Recommended desktop layout:

```text
┌──────────────────────────────────────────────────────────────┐
│ Crow                                      Settings / Status   │
├──────────────────────────────────────────────────────────────┤
│ Command input                                                │
├──────────────────────┬───────────────────────────────────────┤
│ Task filters          │ Task header                           │
│ Task list             │ Current state                         │
│ Approval badge        │ Timeline                              │
│                       │ Approval cards / result / artifacts   │
└──────────────────────┴───────────────────────────────────────┘
```

### Required Regions

Header:

- Product name.
- Runtime status.
- Settings entry.

Command bar:

- Text input.
- Submit button.
- Optional mode selector: Auto, Research, Agent.
- Optional voice button after voice MVP.

Task sidebar:

- All tasks.
- Running.
- Waiting approval.
- Completed.
- Failed.

Task detail:

- Title.
- Status.
- Controls.
- Timeline.
- Active approval card.
- Final result.
- Artifact links.

## 4. Command Entry

### Default State

Placeholder examples:

```text
Ask Crow to research, run an agent, or organize a task...
```

Chinese option:

```text
让 Crow 调研、执行 agent 任务，或创建一个工作任务...
```

### Command Modes

MVP can infer mode automatically, but should expose a manual override if useful:

```text
Auto
Research
Agent
```

Mode behavior:

- Auto: planner classifies task.
- Research: force web research workflow.
- Agent: force agent connector workflow.

### Submit Behavior

When user submits:

```text
Input disabled briefly
Task is created
Task appears in sidebar
Task detail opens
Task starts automatically by default
Timeline receives task.created and task.started
```

Open question:

- Should tasks start automatically or wait for Start?

Recommended MVP:

> Start automatically for low-risk workflows. Require approval before risky actions.

### Command Examples

Research:

```text
调研一下个人 AI 助手市场，重点看桌面端和 agent 产品。
```

Agent:

```text
让 Codex 检查当前 crow 项目的技术文档，找出实现风险。
```

General:

```text
帮我整理一个 Crow MVP 的开发任务列表。
```

Unsupported:

```text
帮我发送邮件给 Alex。
```

Unsupported behavior:

- Create a task.
- Show unsupported state.
- Explain the missing capability.
- Suggest available alternatives.

Example:

```text
Email sending is not available in this MVP.
Crow can draft a task plan or create a research report instead.
```

## 5. Task List

### Task Row

Each row should show:

- Task title.
- Status.
- Created time.
- Small type label: Research, Agent, General.
- Pending approval badge if applicable.

Task row statuses:

```text
Pending
Running
Waiting approval
Paused
Completed
Failed
Cancelled
```

### Filters

MVP filters:

```text
All
Running
Waiting
Completed
Failed
```

### Empty State

When no tasks exist:

```text
No tasks yet.
Ask Crow to research a topic or run an agent task.
```

Avoid explaining every feature in the empty state. Keep it short.

## 6. Task Detail

### Header

Task header should include:

- Title.
- Status pill.
- Task kind.
- Created time.
- Primary controls.

Controls by status:

```text
pending: Start, Cancel
running: Pause, Cancel
waiting_approval: Cancel
paused: Resume, Cancel
completed: Open artifact, Duplicate optional
failed: Retry optional, Cancel hidden
cancelled: no primary action
```

MVP required controls:

- Pause
- Resume
- Cancel
- Open artifact

Retry can be deferred.

### Current State Summary

The top of task detail should always answer:

```text
What is Crow doing right now?
```

Examples:

```text
Searching web sources...
Waiting for approval to write a file...
Codex is running checks...
Research report completed.
```

### Timeline

Timeline is the main trust surface.

Each timeline item should show:

- Event title.
- Event type.
- Time.
- Short message.
- Expandable payload/details when useful.

Timeline item types:

```text
Task
Step
Tool
Agent
Approval
Artifact
Error
```

Default behavior:

- Show concise event text.
- Collapse noisy payloads.
- Expand only when user clicks.
- Auto-scroll while running unless user has manually scrolled up.

### Result Area

Completed tasks should show:

- Final summary.
- Artifact links.
- Sources if research task.
- Agent output summary if agent task.

Failed tasks should show:

- Failure reason.
- Last successful step.
- Suggested next action if available.

## 7. Approval Queue

### Entry Points

Approval requests should appear in:

- Task detail.
- Sidebar badge.
- Dedicated approval queue view.
- macOS notification.

### Approval Card

Required fields:

- Title.
- Risk level.
- Proposed action.
- Preview.
- Task link.
- Approve button.
- Reject button.
- Optional comment.

Approval card example:

```text
Approval Required
Risk: Level 2 - Reversible execution

Crow wants to write a Markdown report to:
~/Library/Application Support/Crow/artifacts/task_123/report.md

[Approve] [Reject]
```

### Risk Display

Risk levels should be readable:

```text
Level 0: Read-only
Level 1: Draft
Level 2: Reversible
Level 3: High-risk
```

Level 3 should visually stand out more than Level 2.

### Approval Behavior

Approve:

```text
Approval status becomes approved
approval.approved event is added
Task resumes
Approval card is dismissed
```

Reject:

```text
Approval status becomes rejected
approval.rejected event is added
Task stops, skips, or fails depending on action
UI shows resulting state
```

MVP recommendation:

> Rejecting a blocking approval should fail the task with a clear `permission_rejected` reason.

## 8. Research Task UX

### Research Timeline

Typical timeline:

```text
Task created
Research started
Generated search queries
Searching web
Found candidate sources
Extracting source 1
Extracting source 2
Extracting source 3
Summarizing findings
Writing Markdown report
Report created
Task completed
```

### Research Result

Result panel should show:

- Report title.
- Short summary.
- Key findings.
- Source list.
- Open artifact button.

Source list item:

- Page title.
- Domain.
- URL.
- Short note.

### Markdown Artifact

Artifact card:

```text
Research Report
Markdown
Created just now
[Open] [Reveal in Finder]
```

MVP should support opening the generated Markdown file with the system default app.

## 9. Agent Task UX

### Agent Timeline

Typical timeline:

```text
Task created
Agent run started
Codex is reading project context
Codex is planning changes
Codex is waiting for approval
Approval approved
Codex resumed
Codex completed
Task completed
```

### Agent Status Card

Show:

- Connector name.
- Run status.
- Current message.
- Started time.
- Cancel button if supported.

Statuses:

```text
Starting
Running
Waiting
Completed
Failed
Cancelled
```

### Agent Logs

MVP should avoid dumping raw verbose logs by default.

Default:

- Show summarized log events.
- Allow expand raw logs if available.

If connector is unavailable:

```text
Codex connector is not configured.
Open Settings to connect it.
```

## 10. Settings UX

MVP settings sections:

```text
General
Model Provider
Agent Connectors
Storage
Permissions
Shortcuts
```

### General

- App version.
- Runtime status.
- Start on login optional.

### Model Provider

- Provider selection.
- API key status.
- Test connection.

Do not show raw API key after saving.

### Agent Connectors

Each connector row:

- Name.
- Status: configured / missing / unavailable.
- Configure button.
- Test button.

### Storage

- Database path.
- Artifact path.
- Open data folder.

### Permissions

Show policy summary:

```text
Read-only actions run automatically.
Draft actions run automatically and show output.
Reversible actions require approval.
High-risk actions always require approval.
```

MVP does not need full policy editing.

### Shortcuts

- Show active global shortcut.
- Reconfigure optional.

## 11. macOS Surface

### Menu Bar

Menu bar menu should include:

```text
Open Crow
New Task
Pending Approvals
Pause All optional
Settings
Quit
```

Menu bar icon states:

```text
Idle
Running
Waiting approval
Error
```

### Global Shortcut

Default:

```text
Option + Space
```

If conflicts occur, show setup state in Settings.

Shortcut behavior:

- If app is hidden, show main window and focus command input.
- If app is open, focus command input.
- If approval is pending, optional: focus approval queue.

### Notifications

Notification triggers:

- Approval required.
- Task completed.
- Task failed.

Notification click behavior:

- Open Crow.
- Navigate to relevant task or approval.

### Floating Panel

Floating panel is optional for MVP and can be V1.1.

When implemented, it should only show:

- Current state.
- Current task.
- Approval required.
- Quick open button.

It should not replace the main task console.

## 12. Voice UX

Voice is optional in MVP, but the UI should leave space for it.

Push-to-talk behavior:

```text
User holds voice button or shortcut
Crow records while held
Crow transcribes
Transcript appears in command input
User can edit or submit
```

Recommended MVP behavior:

> Voice creates or controls tasks, but text remains the fallback.

Supported control phrases later:

```text
pause
continue
cancel
approve
reject
show sources
open report
```

## 13. Empty And Error States

### No Tasks

```text
No tasks yet.
Ask Crow to research a topic or run an agent task.
```

### No Approvals

```text
No approvals pending.
Crow will ask here before sensitive actions.
```

### Connector Missing

```text
Agent connector is not configured.
Connect an agent in Settings to run this task.
```

### Missing Model Provider

```text
Model provider is not configured.
Add a provider key in Settings.
```

### Research No Sources

```text
Crow could not find usable sources.
Try a more specific topic or check search settings.
```

### Tool Failure

```text
The browser extraction tool failed.
Crow kept the task history. You can retry after checking the source URL.
```

## 14. Interaction Rules

### Visibility

- Every running task must show a current state.
- Every tool call must appear in the timeline.
- Every approval must appear in the approval queue.
- Every final artifact must be accessible from task detail.

### Control

- User can cancel a running task.
- User can reject approvals.
- User can open generated artifacts.
- User can inspect failed steps.

### Noise Control

- Do not show raw logs by default.
- Do not expose large JSON payloads unless expanded.
- Summarize agent logs into readable events.

### Safety

- Never hide high-risk actions in generic status text.
- Approval buttons must be explicit.
- Reject should be as easy as approve.
- If a task is blocked, say exactly why.

## 15. Component Inventory

MVP components:

```text
AppShell
CommandBar
TaskSidebar
TaskList
TaskListItem
TaskDetail
TaskHeader
TaskControls
TaskTimeline
TimelineItem
ApprovalCard
ApprovalQueue
ResultSummary
ArtifactCard
SourceList
AgentStatusCard
SettingsView
StatusPill
RiskBadge
EmptyState
ErrorState
```

Optional V1.1 components:

```text
FloatingPanel
VoiceButton
ConnectorSetupWizard
WorkflowTemplateList
RawLogViewer
```

## 16. Accessibility

MVP requirements:

- Keyboard can focus command input.
- Buttons have accessible labels.
- Status should not rely on color only.
- Timeline items should be readable by screen readers.
- Approval actions must be reachable by keyboard.

Keyboard shortcuts:

```text
Option + Space: Focus command input
Command + Enter: Submit command
Escape: Close modal or blur command input
Command + ,: Open Settings
```

## 17. Visual Direction

Crow should feel calm, sharp, and operational.

Recommended qualities:

- Dense enough for repeated work.
- Clear timeline structure.
- Strong status hierarchy.
- Minimal decoration.
- Native-feeling macOS spacing.
- Subtle motion only for state changes.

Avoid:

- Marketing-style hero layouts.
- Oversized cards for every section.
- Heavy gradients.
- One-note dark cyberpunk theme.
- Chat bubble-dominated layout.

## 18. MVP UX Acceptance Criteria

The UX is acceptable when:

- A new user can create a task within 30 seconds.
- A user can tell what Crow is currently doing at a glance.
- A user can find pending approvals without hunting.
- A user can open the final research artifact.
- A user can see why a task failed.
- A user can return after restart and understand previous task history.

The UX is not acceptable if:

- It looks like a generic chat app.
- Task progress is hidden behind a spinner.
- Approvals are buried in logs.
- Research output has no visible sources.
- Agent logs overwhelm the main timeline.
- The user cannot cancel a running task.

## 19. First Screen Recommendation

The first usable screen should be the task console, not a landing page.

Initial first screen:

```text
Command input at top
Empty task list on left
Empty task detail on right
Short empty state in detail panel
Settings accessible but secondary
```

The first user action should be obvious:

```text
Ask Crow to research a topic or run an agent task.
```

## 20. Follow-Up Design Work

After this UX flow, the next useful design artifacts are:

- Low-fidelity wireframe.
- Component-level frontend spec.
- Design tokens.
- macOS menu bar behavior spec.
- Floating panel V1.1 spec.
- Voice interaction spec.
