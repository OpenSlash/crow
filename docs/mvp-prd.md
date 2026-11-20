# Crow MVP PRD: Personal AI Execution Hub

## 1. Background

Crow is a desktop-native personal AI execution hub. It helps users turn intent into action by creating tasks, calling tools and AI agents, showing execution progress, and asking for approval before sensitive actions.

The full Crow vision includes voice interaction, email management, browser operation, research, memory, calendar, files, and orchestration of agents such as Codex and Claude.

The MVP must not attempt to deliver the full vision. It should prove the core product loop:

> A user gives Crow a task. Crow turns it into an observable execution flow, calls tools or agents, asks for approval when needed, and produces a useful result.

## 2. Product Positioning

Crow MVP is not a chatbot.

Crow MVP is:

- A desktop command center for AI-executed tasks.
- A task timeline that makes AI execution observable.
- An approval gate for sensitive actions.
- A lightweight orchestrator for external agents such as Codex, Claude, and existing agent projects.
- A research assistant that can produce sourced Markdown output.

Positioning statement:

> Crow MVP enables users to create, observe, and control AI-executed tasks from a desktop command center.

Chinese positioning:

> Crow MVP 让用户可以从桌面指挥中心创建、观察和控制由 AI 执行的任务。

## 3. Goals

### Product Goals

- Let users create a real task from a desktop command entry.
- Show task progress as a visible timeline.
- Connect at least one external AI agent or existing agent runtime.
- Support approval requests for sensitive actions.
- Complete a web research workflow with sources and Markdown output.
- Persist task history locally.

### Validation Goals

The MVP should validate:

- Users prefer task execution over another chat interface.
- Observable task timelines increase trust.
- Approval gates make users comfortable with AI executing work.
- Agent orchestration is valuable as a unified desktop layer.
- Web research is a strong first non-developer workflow.

### Non-Goals

The MVP will not:

- Support every desktop application.
- Support Windows or Linux.
- Provide always-on wake word detection.
- Provide full email triage.
- Send emails.
- Delete files.
- Submit payments.
- Publicly publish content.
- Provide a plugin marketplace.
- Provide team collaboration.
- Guarantee arbitrary website automation.
- Replace Codex, Claude, Cursor, or other agents.

## 4. Target Users

### Primary User

AI-heavy knowledge workers who already use AI tools daily.

Examples:

- Founders
- Independent developers
- Product managers
- Researchers
- Content creators
- Operators

### Primary User Needs

- Start tasks quickly without opening multiple tools.
- Monitor what AI agents are doing.
- Avoid losing track of long-running AI work.
- Review and approve sensitive actions.
- Generate research output from multiple sources.
- Keep task history and results organized.

### Early Adopter Profile

The first MVP user is comfortable with:

- Installing a macOS desktop app.
- Connecting model provider keys or using configured providers.
- Authorizing browser automation.
- Connecting existing agent projects.
- Reading task logs when needed.

## 5. MVP Scope

Crow MVP includes five product areas:

1. Command entry
2. Task console
3. Approval queue
4. Agent orchestration
5. Web research workflow

### 5.1 Command Entry

Users can open Crow and create a task.

Required capabilities:

- Open main window.
- Use global shortcut to focus command input.
- Enter text command.
- Create task from command.
- See task appear immediately in task list.

Optional for MVP:

- Push-to-talk voice input.
- Command history.
- Quick command templates.

Out of scope:

- Always-on voice wake word.
- Multi-device input.
- Mobile input.

### 5.2 Task Console

Users can observe what Crow is doing.

Required capabilities:

- Task list with status.
- Task detail view.
- Timeline of task events.
- Current running step.
- Tool calls shown in readable form.
- Agent status shown in readable form.
- Final result summary.
- Error state with failure reason.

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

Required task controls:

- Start
- Pause
- Resume
- Cancel
- Open result artifact

Optional for MVP:

- Retry failed step.
- Duplicate task.
- Convert task to workflow.

### 5.3 Approval Queue

Users can approve or reject sensitive actions.

Required capabilities:

- Show approval requests from tools or agents.
- Show risk level.
- Show proposed action.
- Show preview when available.
- Approve action.
- Reject action.
- Add optional comment when rejecting.
- Persist approval decision.

Approval risk levels:

```text
Level 0: Read-only
Level 1: Draft generation
Level 2: Reversible execution
Level 3: High-risk execution
```

MVP policy:

- Level 0: run automatically.
- Level 1: run automatically and show output.
- Level 2: require approval by default in MVP.
- Level 3: always require approval.

Out of scope:

- Organization-level approval policy.
- Role-based approval.
- Approval delegation.

### 5.4 Agent Orchestration

Users can ask Crow to run work through external agents.

Required capabilities:

- Create an agent task from user command.
- Route task to a configured agent connector.
- Show agent run status.
- Show agent logs or summarized log events.
- Surface agent approval requests.
- Cancel agent run where supported.
- Show final agent summary.

Initial connectors:

- Existing agent runtime connector.
- Codex connector if available.
- Claude connector if available.

Minimum acceptable MVP:

- At least one real connector must work end to end.
- Additional connectors can be stubbed behind clear unavailable states.

Out of scope:

- Full multi-agent planning.
- Automatic agent selection across many agents.
- Agent marketplace.
- Autonomous code merge or publish.

### 5.5 Web Research Workflow

Users can ask Crow to research a topic and produce a sourced Markdown report.

Required capabilities:

- Accept research goal.
- Generate search queries.
- Search web.
- Open and extract content from multiple sources.
- Keep source URLs.
- Summarize findings.
- Produce Markdown artifact.
- Show source list.
- Save artifact locally.

Research result should include:

- Summary
- Key findings
- Source list
- Open questions or uncertainty
- Generated Markdown file

Out of scope:

- Paywalled source access.
- Academic citation formatting.
- Guaranteed factual completeness.
- Complex spreadsheet-style analysis.

## 6. User Stories

### Command Entry

As a user, I can press a shortcut and type a task so that I do not need to open a separate AI chat tool.

Acceptance criteria:

- Global shortcut focuses Crow command input.
- Submitting text creates a task.
- Created task appears in the task list within one second.
- Task has a visible status and title.

### Task Timeline

As a user, I can see each step Crow is taking so that I can trust and debug the execution.

Acceptance criteria:

- Task detail shows chronological events.
- Events include step start, tool call, tool result, approval request, failure, and completion.
- Running task visibly updates without manual refresh.
- Failed task shows a human-readable error.

### Approval

As a user, I can approve or reject sensitive actions so that Crow cannot act beyond my comfort level.

Acceptance criteria:

- Approval request appears in task detail and approval queue.
- Request includes action, risk level, and preview.
- Approving resumes the blocked action.
- Rejecting stops or skips the blocked action with a visible event.
- Decision is stored in task history.

### Agent Orchestration

As a user, I can ask Crow to run a task through an AI agent so that I can monitor agent work in one place.

Acceptance criteria:

- User command can create an agent run.
- Agent run emits visible status events.
- Agent completion creates a final summary.
- Agent failure creates a readable failure event.
- If the agent requests approval, Crow shows it in the approval queue.

### Web Research

As a user, I can ask Crow to research a topic so that I receive a useful report with sources.

Acceptance criteria:

- User can enter a research goal.
- Crow searches and reads at least three sources.
- Result includes source URLs.
- Result is saved as a Markdown artifact.
- Task timeline shows research steps.

## 7. Core User Flows

### Flow 1: Command To Task

```text
User presses global shortcut
Crow command input opens
User types task
Crow creates task
Task appears in task list
Task starts running
Timeline updates
Task completes or asks for approval
```

### Flow 2: Agent Orchestration

```text
User asks Crow to run an agent task
Crow creates task
Crow routes request to agent connector
Agent starts
Crow streams agent status
Agent requests approval if needed
User approves or rejects
Agent continues or stops
Crow shows final summary
```

### Flow 3: Web Research

```text
User enters research goal
Crow creates research task
Crow generates search queries
Crow searches web
Crow opens and extracts sources
Crow summarizes findings
Crow writes Markdown artifact
Crow shows final report and sources
```

### Flow 4: Approval Handling

```text
Tool or agent requests sensitive action
Crow pauses task
Crow shows approval request
User reviews risk, action, and preview
User approves or rejects
Crow logs decision
Task resumes, skips, or stops
```

## 8. Functional Requirements

### Task Management

MVP must support:

- Create task.
- List tasks.
- View task detail.
- Persist task state.
- Persist task events.
- Cancel task.
- Show task result artifact.

### Event System

MVP must support:

- Runtime emits events.
- UI receives events in near real time.
- Events are persisted.
- Task detail can be reconstructed from events.

Required events:

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

### Tool Registry

MVP must support:

- Register tools.
- Store tool metadata.
- Execute tool by name.
- Assign tool risk level.
- Route risky tools through Permission Gate.

Initial tools:

```text
browser.search
browser.extract
artifact.write_markdown
agent.run
```

Optional tools:

```text
file.read
file.write
browser.open
```

### Artifact Handling

MVP must support:

- Save Markdown research result.
- Link artifact to task.
- Open artifact from task detail.
- Persist artifact metadata.

### Settings

MVP must support:

- Configure model provider or local model endpoint.
- Configure at least one agent connector.
- Configure storage location.
- View permissions policy.

Optional:

- Configure global shortcut.
- Configure theme.
- Configure default research depth.

## 9. UX Requirements

### Main Window

Main window must include:

- Left task list.
- Main task detail area.
- Command input.
- Approval queue entry point.
- Settings entry point.

### Task Detail

Task detail must include:

- Task title.
- Task status.
- Timeline.
- Current step.
- Approval requests if any.
- Result summary.
- Artifact links.

### Approval UI

Approval UI must include:

- Risk level.
- Proposed action.
- Preview.
- Approve button.
- Reject button.
- Optional comment input.

### Empty States

Required empty states:

- No tasks yet.
- No approvals pending.
- Connector not configured.
- Research task failed due to no sources.

### Native macOS Surface

MVP native surface should include:

- Menu bar icon.
- Global shortcut.
- Basic notification for approval required.

Floating island-style panel is desirable but not required for the first technical MVP.

## 10. Data Requirements

MVP data entities:

```text
Task
TaskStep
TaskEvent
ApprovalRequest
ApprovalDecision
ToolRun
AgentRun
Artifact
Setting
```

Required persistence:

- Task list survives app restart.
- Task events survive app restart.
- Approval decisions survive app restart.
- Artifacts remain accessible after app restart.

Secrets:

- API keys must not be stored in plaintext SQLite.
- On macOS, secrets should be stored in Keychain.

## 11. Permissions And Safety

MVP safety rules:

- High-risk actions always require approval.
- Reversible execution requires approval by default.
- Shell execution is disabled by default.
- Email sending is out of scope.
- File deletion is out of scope.
- Payment and purchasing are out of scope.
- Public publishing is out of scope.

Every approval decision must create a task event.

Every tool call must be logged with:

- Tool name
- Risk level
- Start time
- End time
- Success or failure
- Error message if failed

## 12. Metrics

MVP should capture local product metrics.

Primary metric:

> Successfully completed real tasks per active user per week.

MVP local metrics:

- Created task count.
- Completed task count.
- Failed task count.
- Cancelled task count.
- Approval requested count.
- Approval approved count.
- Approval rejected count.
- Agent task count.
- Research task count.
- Artifact created count.

No analytics service is required for the first local MVP. Metrics can be stored locally first.

## 13. Release Criteria

Crow MVP is releasable internally when:

- User can create a task from command input.
- Task timeline updates live.
- Task state persists after restart.
- At least one agent connector works end to end.
- Web research creates a Markdown artifact with sources.
- Approval request can block and resume a task.
- Approval decisions are persisted.
- App has menu bar icon and global shortcut on macOS.
- API keys are stored securely.
- Failures are visible and understandable.

Crow MVP is not releasable if:

- It only behaves like a chatbot.
- It cannot show execution progress.
- It cannot persist task history.
- It cannot block risky actions.
- It requires manual log inspection for normal usage.

## 14. Dependencies

Technical dependencies:

- Wails desktop app.
- Go runtime.
- React/TypeScript frontend.
- SQLite local store.
- macOS Keychain integration.
- Global shortcut support.
- Browser/search capability.
- At least one model provider.
- At least one agent connector.

External dependencies:

- Model provider account or API key.
- Search provider or browser-based search.
- Existing agent runtime, Codex, or Claude integration.

## 15. Risks

### Risk: MVP Becomes Too Broad

Mitigation:

- Keep email out of core MVP.
- Keep voice optional until task execution loop works.
- Keep floating island optional until main console works.

### Risk: Agent Connector Is Unstable

Mitigation:

- Start with one connector.
- Wrap connector events into Crow's event model.
- Show connector unavailable state clearly.

### Risk: Web Research Quality Is Low

Mitigation:

- Always show sources.
- Show uncertainty and open questions.
- Keep report format simple.
- Avoid unsupported claims.

### Risk: Users Do Not Trust Execution

Mitigation:

- Make timeline visible.
- Log all tool calls.
- Require approval for risky actions.
- Avoid hidden background actions.

### Risk: Native macOS Work Delays MVP

Mitigation:

- Require only menu bar, shortcut, and notifications for MVP.
- Defer polished floating island.
- Keep Swift/AppKit helper thin.

## 16. Open Questions

- Which agent connector should be implemented first?
- Which model provider should be the default?
- Should web research use a search API or browser-based search first?
- Should voice input be included in the first internal release or immediately after?
- Should the floating island be part of MVP or V1.1?
- What is the default local storage location?
- How long should task history be retained?
- Should users be able to edit generated Markdown inside Crow?
- Should workflows be introduced in MVP or after repeated task patterns appear?

## 17. Suggested Build Order

1. Wails app skeleton.
2. React task console shell.
3. SQLite task storage.
4. Go task engine.
5. Event bus and live timeline.
6. Approval queue.
7. One agent connector.
8. Web research workflow.
9. Artifact storage.
10. macOS menu bar and global shortcut.
11. Keychain secret storage.
12. Internal dogfood release.

## 18. MVP Definition Of Done

Crow MVP is done when one user can complete these three workflows without developer assistance:

1. Create a task from the desktop command entry and observe its timeline.
2. Run an external AI agent task and review its final summary.
3. Run a web research task and open the generated Markdown report with sources.

The MVP should feel like a small but real execution hub, not a demo chatbot.
