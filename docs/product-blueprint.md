# Crow Product Blueprint

Crow is a personal AI execution hub. It lives on the user's computer, understands goals through voice and text, reads authorized context, calls tools and AI agents, completes real tasks, and asks for confirmation before sensitive actions.

Short positioning:

> Crow turns intent into action.

Chinese positioning:

> Crow 把你的意图变成行动。

## 1. Product Vision

Crow aims to become the user's second working brain on the desktop.

It should be:

- Always available through voice, shortcuts, menu bar, or floating UI.
- Context-aware across browser, email, files, calendar, clipboard, and coding tools.
- Action-oriented, not only conversational.
- Transparent while executing, with visible steps, tool usage, and pending approvals.
- Safe by default, especially for sending, deleting, publishing, paying, or committing.
- Adaptive over time through user preferences, workflows, and long-term memory.

Long-term vision:

> Turn the personal computer from a passive tool into an active collaborator.

## 2. Target Users

Crow can eventually serve general users, but the first version should focus on high-frequency, high-value users who already trust AI tools.

### First Segment: AI-Heavy Knowledge Workers

Examples:

- Independent developers
- Founders
- Product managers
- Researchers
- Content creators
- Operators

Common needs:

- Switch between email, browser, docs, chat, code tools, and AI tools all day.
- Use ChatGPT, Claude, Codex, Cursor, or similar tools already.
- Have many tasks that AI can advance but still require human approval.
- Are willing to grant local permissions if the product saves visible time.

### Second Segment: Professional Knowledge Workers

Examples:

- Consultants
- Investors
- Sales teams
- Legal teams
- Marketers
- HR and operations teams

Common needs:

- Research topics.
- Summarize meetings.
- Prepare reports.
- Follow up with customers.
- Organize email and calendar.
- Move information across systems.

### Third Segment: General Personal Users

Examples:

- Personal email management
- Shopping research
- Travel planning
- File organization
- Web browsing assistance

This market is large, but less suitable for the first release because needs are fragmented and trust requirements are higher.

## 3. Product Shape

Crow should have four interface layers.

### Persistent Entry

This is Crow's visible presence on the desktop.

Possible forms:

- macOS menu bar icon
- Dynamic Island style floating capsule
- Shortcut launcher
- Voice listening indicator
- Compact task status pill

States:

- Idle
- Listening
- Thinking
- Executing
- Waiting for approval
- Completed
- Failed or needs takeover

### Conversation Entry

Conversation is the most natural input path, but not the whole product.

Users should be able to say:

- "整理今天的重要邮件。"
- "调研一下个人 AI 助手市场，重点看桌面端和 agent 产品。"
- "打开昨天那个项目，让 Codex 继续修复测试失败。"
- "把这篇网页总结成中文，并保存到我的知识库。"
- "查一下这家公司，做一页投资备忘。"

Required capabilities:

- Text input
- Voice input
- File, webpage, and selected text references
- Current context references
- Multi-turn correction
- Mid-task interruption

### Task Console

This is the core difference from a normal chatbot.

Every task should become an observable execution timeline.

Example:

```text
Task: 整理今天的重要邮件

1. Reading unread Gmail messages
2. Found 38 messages
3. Classifying: important / reply needed / notification / bill / noise
4. Found 5 messages that need action
5. Drafting 3 replies
6. Waiting for confirmation before sending
```

The user can:

- Pause
- Resume
- Cancel
- Modify instructions
- View original sources
- Take over the browser
- Approve or reject actions
- Save results
- Reuse the task as a workflow

### Memory And Workflow Center

Crow needs editable memory. Memory cannot be a black box.

It should store:

- Personal preferences: language, tone, output format, default tools.
- Work preferences: folders, projects, mailboxes, websites.
- Safety rules: actions that always require approval.
- Common workflows: morning briefing, email triage, research report, coding task, meeting summary.
- Project memory: repos, clients, topics, document libraries.

## 4. Core Modules

### Voice Interaction

Voice is required for the Jarvis-like experience, but the MVP should avoid overinvesting in always-on wake word detection.

MVP:

- Hold-to-talk or shortcut-to-talk
- Speech to text
- Optional spoken response
- Voice interruption while tasks are running
- Short control commands: stop, continue, approve, rewrite, cancel

Later:

- Wake word
- Continuous listening
- Local speech recognition
- Speaker recognition
- Multi-device voice entry

### Context Awareness

MVP context sources:

- Active app
- Browser page
- Clipboard
- Selected text
- File path
- Current project
- Recent task history

Later context sources:

- Screen OCR
- Browser DOM
- Email thread context
- Calendar context
- Git repository status
- IDE current file and diagnostics

### Tool Execution

Tools should be standardized behind a common protocol.

Initial tools:

- Browser: search, open page, extract content, fill forms.
- Email: read, classify, summarize, draft, confirm before send.
- Calendar: read events, identify conflicts, create draft events.
- Files: read, organize, rename, generate documents.
- Search: web search, source comparison, citation collection.
- Codex and Claude: create tasks, monitor execution, summarize results, request approval.
- Notes and Markdown: save research output and task results.
- Shell: developer mode only, with strict approval.

### Planning

The planning layer should:

1. Infer the desired outcome.
2. Break it into executable steps.
3. Classify the risk level of each step.

Example:

```text
User: 帮我处理今天邮件

Plan:
1. Read unread email: low risk, automatic
2. Classify and summarize: low risk, automatic
3. Draft replies: medium risk, automatic but not sent
4. Send email: high risk, requires confirmation
```

### Permission Model

Crow's trust depends on clear permissions.

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

Default policy:

- Level 0 runs automatically.
- Level 1 runs automatically and shows the result.
- Level 2 depends on user settings.
- Level 3 always requires explicit approval.

## 5. MVP Scope

The first version should focus on three complete scenarios instead of many shallow features.

### Scenario 1: Email Triage

Goal: save 10 to 20 minutes every morning.

Capabilities:

- Read unread email
- Classify by importance
- Extract action items
- Summarize threads
- Draft replies
- Send only after confirmation
- Generate daily email digest

Example:

```text
User: Crow，帮我处理一下今天的邮件。

Crow:
我发现 42 封新邮件，其中 6 封重要，4 封需要回复。
我已经起草了 3 封回复，1 封涉及合同金额，需要你确认措辞。
```

### Scenario 2: Web Research

Goal: make Crow a reliable research assistant.

Capabilities:

- Search based on a goal
- Open multiple pages
- Extract key content
- Compare sources
- Mark citations
- Output summaries, tables, and conclusions
- Save as Markdown, Notion, or local document

Example:

```text
User: 调研一下个人 AI 助手市场，重点看桌面端和 agent 产品。

Crow:
我会搜索最近 12 个月的产品和融资信息，整理竞品、定位、核心功能和机会点。
```

### Scenario 3: AI Agent Orchestration

Goal: wrap existing agent capabilities into a visible command system.

Capabilities:

- Create Codex and Claude tasks
- Monitor execution status
- Show pending approvals
- Summarize completed work
- Suggest next steps after failure
- Coordinate multiple agents in parallel

Example:

```text
User: 让 Codex 修复当前项目的测试失败，让 Claude review 一下产品文案。

Crow:
我已创建两个任务：
Codex 正在检查测试失败。
Claude 正在审查文案。
Codex 现在请求运行测试，是否批准？
```

## 6. Explicit Non-Goals

Crow V1 should not:

- Prioritize mobile first.
- Promise full desktop automation.
- Deeply integrate with every app.
- Build complex team collaboration.
- Build a public plugin marketplace.
- Allow high-risk actions without confirmation.
- Focus on emotional companionship.
- Focus on entertainment chat.
- Promise stable operation on every website.

These can become later opportunities, but they are not first-version differentiators.

## 7. Technical Architecture

Recommended high-level architecture:

```text
Crow Desktop App
├── Interaction Layer
│   ├── Voice Input
│   ├── Text Command
│   ├── Shortcut
│   └── Floating UI
│
├── Context Layer
│   ├── Active App
│   ├── Browser Context
│   ├── Clipboard
│   ├── Files
│   ├── Email
│   └── Calendar
│
├── Intelligence Layer
│   ├── Intent Detection
│   ├── Task Planner
│   ├── Risk Classifier
│   ├── Memory Retriever
│   └── Response Generator
│
├── Execution Layer
│   ├── Browser Agent
│   ├── Email Agent
│   ├── Research Agent
│   ├── Codex Agent
│   ├── Claude Agent
│   ├── File Agent
│   └── Shell Agent
│
├── Control Layer
│   ├── Permission Gate
│   ├── Human Approval
│   ├── Task Timeline
│   ├── Logs
│   └── Rollback Hints
│
└── Memory Layer
    ├── User Preferences
    ├── Task History
    ├── Project Memory
    ├── Contact Memory
    └── Workflow Templates
```

### Desktop Technology

For a macOS-first product:

- App: SwiftUI + AppKit
- Floating UI: NSPanel, menu bar extra, accessibility APIs
- Local service: Node, Rust, Python, or Go
- IPC: Unix domain socket, gRPC, or local HTTP
- Local database: SQLite
- Vector storage: SQLite vec, LanceDB, or Chroma
- Browser control: Playwright, Chrome extension, or CDP
- Speech recognition: Whisper, local model, or cloud API
- TTS: system TTS, OpenAI TTS, ElevenLabs, or similar
- Agent access: existing agent project as Execution Layer

For future cross-platform support:

- Use Tauri rather than Electron where possible.
- Keep core runtime separate from the desktop shell.
- Implement native OS capabilities through sidecars or plugins.

Recommended direction:

> macOS native entry + local agent runtime + standardized tool protocol.

## 8. Information Architecture

Crow should have five main areas:

```text
1. Command
Task input, voice conversation, quick commands.

2. Tasks
Current tasks, task history, execution steps, approval queue.

3. Context
Current webpage, email, file, project, selected text.

4. Workflows
Morning briefing, email triage, web research, coding task, meeting summary.

5. Memory & Permissions
Preferences, long-term memory, tool authorization, safety rules.
```

The floating UI should show only critical state. Complex operations should open the main window.

## 9. Core Experience Examples

### Morning Briefing

```text
User: Crow，开始晨间简报。

Crow:
我会检查邮件、日历和待办。涉及发送或修改内容时会先确认。

Execution:
- Read today's calendar
- Check unread email
- Extract reply-needed items
- Detect one meeting conflict
- Generate today's priority list
- Draft two replies
```

### Web Research

```text
User: 帮我调研 AI 桌面助手竞品，重点看功能、定价和差异化。

Crow:
我会搜索公开资料，优先使用官网、Product Hunt、GitHub 和新闻来源。

Result:
已查看 18 个来源，保留 9 个可信来源。
我整理了 7 个竞品，分为桌面助手、浏览器 Agent、开发者 Agent、自动化工具四类。
```

### Development Orchestration

```text
User: 让 Codex 看一下 crow 项目当前还有什么问题。

Crow:
我会让 Codex 扫描项目结构、运行测试，并输出风险列表。运行命令前会请求确认。

Result:
Codex 发现 3 个问题：
1. 邮件工具缺少权限失败处理
2. 浏览器任务没有超时机制
3. 任务日志没有持久化

是否让 Codex 先修复第 2 项？
```

## 10. Brand Direction

Crow is a strong code name and can become the real product name.

Useful associations:

- Intelligent
- Observant
- Strong memory
- Tool-using
- Good at finding paths through complex environments
- Good at collecting and organizing information

Brand tone:

- Calm
- Agile
- Reliable
- Slightly mysterious
- Not dark or cyberpunk

Possible lines:

- Crow turns intent into action.
- Ask once. Crow handles the steps.
- A personal AI command center.
- 说出目标，Crow 推进过程。
- 你的个人 AI 执行中枢。
- 不是回答问题，而是完成任务。

## 11. Metrics

North Star Metric:

> Weekly successfully completed user-authorized tasks.

Crow should not optimize for DAU, chat volume, or token usage as the primary signal. Its value is task execution.

Supporting metrics:

- Completed tasks per active user per week
- Task success rate
- User takeover rate
- User cancellation rate
- Approval pass rate for high-risk actions
- Estimated time saved per task
- Workflow reuse rate
- Workflow creation count
- 7-day and 30-day retention

First-quarter OMTM:

> Each activated user completes at least 5 real tasks per week.

A real task must include at least one tool call or one external context read. Pure Q&A does not count.

## 12. Business Model

Crow is better suited to a premium subscription than a low-priced utility.

### Free

- Local entry
- Basic chat
- Limited task execution
- Webpage and local file summaries
- Limited workflows

### Pro

- Email, calendar, and browser automation
- Agent orchestration
- Long-term memory
- Advanced voice
- Monthly task allowance
- Multi-model access

### Power / Team

- Multiple accounts
- Team knowledge base
- Audit logs
- Custom tools
- Enterprise permission policies
- Private model or BYOK support

Early pricing can use BYOK:

- Users bring OpenAI, Anthropic, Gemini, Kimi, or other model keys.
- Crow charges for the software layer.
- This reduces model cost pressure during early validation.

## 13. Competitive Landscape

Crow overlaps with several categories but should avoid competing on chat quality alone.

- ChatGPT / Claude desktop: strong conversation, weaker local execution and orchestration.
- Raycast AI: strong launcher, weaker long-running task execution.
- Zapier / Make: strong automation, weaker natural interaction and desktop context.
- Rewind / Limitless-style products: strong memory, weaker action execution.
- Open Interpreter / computer-use products: strong experimental execution, weaker stability and safety boundaries.
- Cursor / Codex / Claude Code: strong coding tasks, not general personal assistants.
- Open Island: strong agent status panel, not a full execution assistant.

Crow's differentiation:

> Persistent desktop presence + voice interaction + cross-tool execution + observable task timeline + permission control + multi-agent orchestration.

## 14. Defensibility

Crow's defensibility is in the system layer, not the base model.

Potential moats:

- Personal context accumulation: preferences, workflows, projects, contacts, and tools.
- Deep tool integrations: email, browser, files, calendar, agents, IDEs.
- Task execution history: Crow learns how users approve, reject, and revise actions.
- Permission model: safety and transparency become trust assets.
- Workflow templates: users can reuse and share task flows.
- Local-first architecture: attractive to privacy-sensitive users.

## 15. Key Risks

### Scope Creep

Mitigation:

- MVP only covers email triage, web research, and agent orchestration.
- Each scenario must work end to end.
- Do not promise arbitrary task execution.

### Execution Instability

Mitigation:

- Prefer APIs first, browser automation second, screen control last.
- Every task needs failure recovery and user takeover.
- Make capability boundaries visible.

### User Trust

Mitigation:

- Default to read-only.
- Always confirm high-risk actions.
- Show every execution step.
- Keep task logs and rollback hints.

### Voice As A Gimmick

Mitigation:

- Use voice primarily for task input and control.
- Support short commands: pause, continue, approve, cancel, rewrite.
- Avoid long companionship-style conversation in V1.

### Direct Competition With ChatGPT Desktop

Mitigation:

- Do not position Crow as a better chatbot.
- Emphasize execution, context, task timelines, and tool orchestration.
- Start with AI-heavy users and developers.

## 16. Four-Week MVP Roadmap

### Week 1: Product Skeleton

Goal: Crow can be opened and can create tasks.

Deliverables:

- Desktop persistent entry
- Shortcut launcher
- Text input
- Basic task list
- Task states: pending, running, waiting approval, completed, failed
- Local SQLite task history

### Week 2: Agent Orchestration

Goal: connect existing agent project.

Deliverables:

- Create Codex and Claude tasks
- Receive status updates
- Show pending approvals
- Persist task logs
- Jump to execution context
- Generate completion summary

### Week 3: Web Research

Goal: complete a useful research workflow.

Deliverables:

- Search
- Open webpages
- Extract main content
- Summarize multiple sources
- Capture citations
- Output Markdown
- Save local document

### Week 4: Voice And Email Loop

Goal: create a Jarvis-like daily-use experience.

Deliverables:

- Push-to-talk voice input
- TTS response
- Email reading
- Email classification
- Email summary
- Reply drafts
- Confirmation before sending

By the end of week 4, Crow should demonstrate:

1. Research a topic and generate a report.
2. Ask Codex or Claude to perform a task and report progress.
3. Triage today's email and draft replies.

## 17. MVP Release Criteria

Crow MVP is ready when:

- A user can naturally delegate a real task.
- Crow can break the task into visible execution steps.
- Crow can call at least two external tool types.
- Crow asks for confirmation before sensitive actions.
- Crow produces a result the user wants to keep or use.

If it only chats, it is not Crow yet.

If it executes but the user cannot see what happened, it is not Crow yet.

If it can execute high-risk actions without control, it is unsafe.

## 18. Final Definition

Crow is a personal AI execution hub. It lives on the desktop, understands goals through voice and text, reads authorized context, calls tools and AI agents, completes real tasks, and asks for confirmation before sensitive actions.

The first version should prove one core belief:

> Users do not only want AI to answer. They want AI to responsibly move work forward.
