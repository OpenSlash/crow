# Crow Executor Adapter Kit

Crow is the voice/UI control plane. It does not own skills or workflows. It understands the user's request, keeps context, asks for approval when needed, and delegates execution to an executor.

ACP is Crow's primary executor protocol for code and agent tools. Codex, Claude Code, OpenClaw, and future coding agents should enter Crow through an `adapter: "acp"` connector when they support the Agent Client Protocol. Crow does not own the user's executor account, API key, model subscription, or base URL. Crow launches and supervises a user-installed executor and lets that executor read its own local configuration.

## Adapter Types

### ACP Connector

ACP uses JSON-RPC over stdio and gives Crow a common execution surface:

- session creation
- prompt turns
- streamed agent output
- tool call updates
- permission requests
- cancellation-ready lifecycle

This is the preferred connector type for high-capability local agents. The user supplies or already has the installed agent binary. Service configuration remains owned by that agent and is read from the user's existing machine configuration.

Crow does not auto-register Codex or Claude just because binaries are found on `PATH`. A connector must be explicitly installed as `~/.crow/executors/*.json` or another configured executor directory. This keeps Codex, Claude Code, OpenClaw, browser agents, and MCP tools as peer plugins that can later be distributed through a connector marketplace.

### Command Adapter

Most future tools should start as command adapters. A command adapter is a local executable, script, or shell command that receives Crow task data through environment variables and emits JSONL events on stdout.

Crow loads command adapters from JSON files at dispatch time, so editing adapter JSON takes effect on the next task without rebuilding Crow.

## Config Locations

Crow scans these directories:

- `$CROW_EXECUTOR_DIRS` as a path-list.
- `$CROW_EXECUTOR_DIR`.
- `~/.crow/executors`.
- `<CROW_EXECUTOR_CWD>/.crow/executors`.
- `<current working directory>/.crow/executors`.

Files must end in `.json`.

## Adapter JSON

### ACP Codex Connector Manifest

```json
{
  "id": "codex",
  "name": "Codex",
  "description": "Delegates code and agent tasks to a user-installed Codex CLI.",
  "version": "0.1.0",
  "publisher": "Crow",
  "homepage": "https://github.com/openai/codex",
  "adapter": "acp",
  "enabled": true,
  "kinds": ["code", "agent"],
  "command": "'/Users/you/Library/Application Support/Crow/executors/codex-acp/node_modules/.bin/codex-acp'",
  "supportsStreaming": true,
  "supportsApproval": true
}
```

`command` starts the ACP agent over stdio through `sh -lc`, so quote paths with spaces. The Codex CLI has no built-in ACP mode; the ACP bridge is the npm package `@agentclientprotocol/codex-acp` (formerly `@zed-industries/codex-acp`). Install it into a Crow-only folder so it does not touch a global Codex install:

```bash
D="$HOME/Library/Application Support/Crow/executors/codex-acp"
npm install --prefix "$D" @agentclientprotocol/codex-acp@2.6.0
```

It bundles its own Codex runtime and reads the user's existing login and settings from `~/.codex`; sessions it runs appear in Codex's history. Pin a version that has been published for a while rather than the newest.

Do not put API keys or model provider base URLs in this manifest. For user-side executors such as Codex, Crow should not ask the user to duplicate credentials. The executor should read its own existing local login, config files, and environment.

### Command Adapter

```json
{
  "id": "openclaw",
  "name": "OpenClaw",
  "description": "Delegates browser and research tasks to OpenClaw.",
  "version": "0.1.0",
  "publisher": "OpenClaw",
  "homepage": "https://example.com/openclaw",
  "adapter": "command",
  "enabled": true,
  "kinds": ["browser", "research", "general"],
  "command": "/usr/local/bin/openclaw crow-adapter",
  "supportsStreaming": true,
  "supportsApproval": false,
  "env": {
    "OPENCLAW_PROFILE": "default"
  }
}
```

## Runtime Contract

Crow starts the command through `sh -lc`.

The adapter receives:

```bash
CROW_EXECUTOR_ID
CROW_TASK_ID
CROW_TASK_KIND
CROW_TASK_COMMAND
CROW_TASK_JSON
```

`CROW_TASK_JSON` contains:

```json
{
  "taskId": "task_20260610120000000000000",
  "kind": "research",
  "command": "Research the best calendar apps",
  "context": {
    "dataDir": "...",
    "source": "crow"
  },
  "approvalPolicy": "required_for_side_effects"
}
```

## JSONL Output

Each stdout line can be either plain text or a Crow event JSON object.

Preferred JSONL:

```json
{"type":"executor.started","title":"OpenClaw started","message":"Preparing browser session"}
{"type":"step.started","title":"Searching","message":"Collecting sources"}
{"type":"executor.output","title":"Finding","message":"Three strong options found"}
{"type":"task.completed","title":"Done","message":"Final recommendation ready"}
```

Plain text still works; Crow records it as executor output.

## Routing

Crow currently routes by task kind:

- `code`, `agent`: the enabled executor that declares those kinds, preferably an ACP connector.
- `browser`, `research`, `general`: Hermes or other configured command adapters.
- `email`: Mail executor.

This is intentionally executor-based, not skill-based. The next router upgrade should be an intent router that chooses the best executor based on user need, available connectors, health, risk, and context.

## Compatibility

The old command environment variables still work as local development compatibility shims:

- `CROW_AGENT_COMMAND`
- `CROW_HERMES_COMMAND`
- `CROW_MAIL_COMMAND`

For new integrations, prefer JSON adapters under `~/.crow/executors`.

## Marketplace Direction

A distributable connector should be a small package containing:

- a signed connector manifest
- adapter type and version constraints
- supported task kinds
- required local command checks
- optional setup hints for the executor's own login/configuration flow
- health check metadata
- approval capabilities

Crow Core should only provide the loader, router, supervision loop, approval UI, and connector settings surface. Executor-specific behavior belongs to connector packages.
