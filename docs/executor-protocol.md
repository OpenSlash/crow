# Crow Executor Protocol

Crow is the control plane. Executors such as Codex, Hermes, browser agents, mail agents, and shell tools do the actual work.

## Task Request

Crow sends a task request to an executor:

```json
{
  "taskId": "task_20260604120000000000000",
  "kind": "code",
  "command": "Fix the login bug in this project",
  "context": {
    "cwd": "/path/to/crow",
    "source": "voice"
  },
  "approvalPolicy": "required_for_side_effects"
}
```

## JSONL Events

Executors should write one JSON object per line to stdout.

```json
{"type":"step.started","title":"Reading project","message":"Scanning source files"}
{"type":"step.completed","title":"Issue found","message":"Token refresh fails after expiry"}
{"type":"approval.required","title":"Apply patch?","message":"Modify auth.ts","preview":"diff..."}
{"type":"artifact.created","title":"Patch created","message":"auth.patch"}
{"type":"task.completed","title":"Done","message":"Login bug fixed"}
```

## Event Fields

- `type`: Crow timeline event type.
- `title`: short UI title.
- `message`: detailed message.
- `subtitle`: optional task subtitle override.
- `status`: optional task status override.
- `preview`: optional approval/artifact preview.

If `status` is omitted, Crow infers it from `type`.

## Adapter Contract

Adapters translate between Crow and executor-specific APIs:

```text
Crow Task -> ACP session/prompt or command input
Executor output -> ACP session/update or Crow JSONL events
```

Crow should not depend on executor internals. ACP is the preferred protocol for high-capability code agents. Command adapters remain useful for simple scripts and legacy tools.

## Executor Adapter Kit

Crow supports executor adapters through JSON config files. Prefer this for delegated tools:

```text
~/.crow/executors/*.json
<project>/.crow/executors/*.json
```

See [executor-adapter-kit.md](./executor-adapter-kit.md).

Codex, Claude Code, OpenClaw, browser agents, and MCP tools should all enter Crow through this adapter layer. When available, use `adapter: "acp"` so streaming, tool calls, approvals, and sessions share one protocol. Crow Core should not assume any one of them is installed or bundled with the product.

## Environment Configuration

Crow Desktop loads `.env` from the project root during local development.

```bash
CROW_AGENT_COMMAND='your-agent-adapter'
CROW_HERMES_COMMAND='your-hermes-adapter'
CROW_MAIL_COMMAND='your-mail-adapter'
```

These environment variables are compatibility shims, not the plugin mechanism. New tools should use executor adapter JSON so they can be added, removed, upgraded, or distributed without rebuilding Crow.

Command executors receive:

```bash
CROW_EXECUTOR_ID
CROW_TASK_ID
CROW_TASK_KIND
CROW_TASK_COMMAND
CROW_TASK_JSON
```

Minimal test executor:

```bash
CROW_AGENT_COMMAND='printf "%s\n" "{\"type\":\"step.started\",\"title\":\"Reading project\",\"message\":\"Scanning files\"}" "{\"type\":\"task.completed\",\"title\":\"Done\",\"message\":\"Completed\"}"'
```
