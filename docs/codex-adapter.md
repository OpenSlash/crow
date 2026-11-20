# Crow Codex Connector

Crow supports Codex through an explicitly installed ACP executor connector for `code` and `agent` tasks. Crow no longer supports the older native Codex `app-server` adapter.

## Runtime Shape

Crow requires a Codex connector manifest before it will delegate work to Codex.

Flow:

```text
Crow task
-> installed ACP Codex connector
-> codex acp
-> ACP initialize
-> ACP session/new
-> ACP session/prompt
-> ACP session/update notifications
-> Crow task timeline
```

Crow supervises the ACP session, maps streamed updates into Crow task events, and bridges ACP permission requests into Crow approvals.

## Configuration

Install a connector manifest at `~/.crow/executors/codex.json`:

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
  "command": "codex acp",
  "supportsStreaming": true,
  "supportsApproval": true
}
```

`command`
: Starts the Codex ACP agent over stdio. Adjust this to the installed Codex ACP command when the CLI exposes a different entrypoint.

Crow does not ask the user to enter Codex API keys, model provider base URLs, or subscription credentials. Codex should use the user's existing local Codex login, config files, and environment exactly as it does when launched from the terminal.

`CROW_EXECUTOR_CWD`
: Optional workspace directory for ACP executors. If empty, Crow uses its current working directory.

## Current Boundary

Implemented:

- Load Codex only when an ACP executor connector manifest is configured.
- Start ACP agents over stdio.
- Create ACP sessions and send prompt turns for Crow `code` / `agent` tasks.
- Bridge ACP permission requests into Crow approvals.
- Map ACP plans, assistant chunks, tool starts/completions, usage updates, errors, and completion into Crow timeline events.

Next:

- Add explicit UI controls to reset or switch ACP connector context.
- Persist in-flight ACP approvals across app restarts.
- Add ACP session resume/load support when agents advertise it.
