# Crow Skill Protocol

Crow skills are local capability manifests that describe what Crow can ask an agent or executor to do.

Crow is the experience and orchestration layer. Codex, Hermes, openclaw, browser automation, mail automation, and shell commands are executors behind skills.

## Current Implementation

Crow Desktop loads JSON skill manifests from:

```text
~/Library/Application Support/Crow/skills/*.json
```

On first startup, Crow creates example manifests:

- `codex.code_review`
- `email.triage`
- `web.research`

The console lists registered skills in the task sidebar.

The Codex adapter injects the enabled skill catalog into the agent prompt. This makes skills visible to the agent before direct skill execution is implemented.

Crow also performs a lightweight match when a task is created:

- only `enabled=true` skills are considered
- triggers are preferred over id, name, or description token matches
- the selected skill is written as a `skill.matched` timeline event
- the selected skill is injected into `ExecutorRequest.context`
- Codex receives the selected skill and full enabled skill catalog in its prompt

This means the current runtime can recognize and explain the intended capability, while direct skill invocation remains a later step.

Low-risk command skills can now run directly:

- `type` must be `command`
- `enabled` must be `true`
- `risk` must be `low`
- `command` must be present

Command skill stdout can emit plain text or Crow JSONL executor events. Plain text is recorded as `skill.output`.

Command skills with `approval_required` or `high` risk are persisted as `skill_runs`, create a Crow approval request, and pause. When the user approves, Crow resumes the stored skill run and executes the original command with the original task context.

Workflow skills can now run command steps in order and hand off to an executor as the final step:

- `type` must be `workflow`
- `steps` must contain command steps, optionally followed by one executor step
- each step emits `workflow.step.started` and `workflow.step.completed`
- executor-backed steps currently must be the final workflow step because executors can complete the task
- supported final executor step types: `codex`, `agent`, `code`, `hermes`, `browser`, `openclaw`, `research`, `mail`, `email`
- low-risk workflows run immediately
- approval-gated workflows are stored as `skill_runs` and resume after approval

## Manifest

```json
{
  "id": "codex.code_review",
  "name": "Codex code review",
  "description": "Ask Codex to inspect the current project and return defects, risks, and test gaps.",
  "type": "agent",
  "executor": "codex",
  "risk": "low",
  "triggers": ["代码审查", "review this code", "检查项目"],
  "enabled": true
}
```

Command skill example:

```json
{
  "id": "system.time",
  "name": "System time",
  "description": "Return the current local system time.",
  "type": "command",
  "executor": "local",
  "command": "date '+%Y-%m-%d %H:%M:%S %Z'",
  "risk": "low",
  "triggers": ["现在几点", "当前时间", "current time", "system time"],
  "enabled": true
}
```

Approval-gated command skill example:

```json
{
  "id": "system.open_home",
  "name": "Open home folder",
  "description": "Open the user's home folder in Finder after approval.",
  "type": "command",
  "executor": "local",
  "command": "open \"$HOME\"",
  "risk": "approval_required",
  "triggers": ["打开主目录", "open home folder"],
  "enabled": true
}
```

Workflow skill example:

```json
{
  "id": "workflow.local_brief",
  "name": "Local workflow brief",
  "description": "Run a two-step local workflow that demonstrates Crow workflow execution.",
  "type": "workflow",
  "executor": "local",
  "risk": "low",
  "triggers": ["本地简报", "workflow demo", "local workflow"],
  "steps": [
    {
      "id": "collect",
      "name": "Collect context",
      "type": "command",
      "command": "printf 'Collected local task context: %s\n' \"$CROW_TASK_COMMAND\""
    },
    {
      "id": "summarize",
      "name": "Summarize result",
      "type": "command",
      "command": "printf '%s\n' '{\"type\":\"step.completed\",\"title\":\"Workflow summary\",\"message\":\"Crow executed a multi-step local workflow.\"}'"
    }
  ],
  "enabled": true
}
```

Workflow with Codex final step:

```json
{
  "id": "workflow.codex_brief",
  "name": "Codex workflow brief",
  "description": "Prepare local context, then ask Codex to produce the final assistant-facing brief.",
  "type": "workflow",
  "executor": "codex",
  "risk": "low",
  "triggers": ["codex workflow", "codex 工作流", "让 codex 做简报"],
  "steps": [
    {
      "id": "prepare",
      "name": "Prepare context",
      "type": "command",
      "command": "printf 'Prepared Crow workflow context for: %s\n' \"$CROW_TASK_COMMAND\""
    },
    {
      "id": "codex_final",
      "name": "Ask Codex",
      "type": "codex",
      "command": "用两句话总结这个 Crow workflow 任务的目标和下一步建议。只输出面向用户的最终结论。"
    }
  ],
  "enabled": true
}
```

Fields:

- `id`: stable capability id.
- `name`: user-facing name.
- `description`: agent-readable description.
- `type`: `prompt`, `agent`, `command`, or `workflow`.
- `executor`: `codex`, `hermes`, `openclaw`, `mail`, `browser`, or another adapter id.
- `command`: optional local command for command skills.
- `steps`: ordered workflow steps. `command` steps can appear anywhere; executor-backed steps must currently be final.
- `risk`: `low`, `approval_required`, or `high`.
- `triggers`: phrases that imply this skill.
- `enabled`: whether Crow should expose this skill to agents.

## Compatibility Model

Crow should not become locked to a single skill protocol.

```text
Codex skill       -> Crow skill adapter -> Crow capability
Hermes workflow   -> Crow skill adapter -> Crow capability
openclaw action   -> Crow skill adapter -> Crow capability
Local command     -> Crow skill         -> Crow capability
```

Crow owns:

- discovery
- user-visible capability names
- approval policy
- runtime state
- voice output
- final answer formatting

Executors own:

- domain execution
- tool-specific protocol details
- raw tool progress

## Next Runtime Step

The next implementation should add executor-backed workflow steps:

```text
User request
-> Crow matches enabled skill by trigger or agent selection
-> Crow creates a skill run
-> Crow asks approval when risk requires it
-> Crow calls local command, Codex, Hermes, openclaw, browser, mail, or model steps
-> Executor result returns to Crow agent context
-> Crow speaks and displays the final answer
```

Direct execution should wait until approval and result-shaping are wired, because skills can become powerful quickly.

## Executor Context

When a skill is matched, command adapters receive it through `CROW_TASK_JSON.context`:

```json
{
  "skillId": "codex.code_review",
  "skillName": "Codex code review",
  "skillType": "agent",
  "skillExecutor": "codex",
  "skillRisk": "low",
  "skillMatchReason": "trigger:代码审查"
}
```

External adapters such as Hermes or openclaw can use this context to select their internal workflow or skill protocol.
