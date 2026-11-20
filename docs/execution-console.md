# Execution Console

Crow Console renders task events as execution blocks instead of a raw event log.

## Goals

- Show the current task as an observable execution, not a debug trace.
- Keep streaming output readable by merging adjacent `executor.output` events.
- Make approvals and tool calls visually distinct from generic steps.

## Event Mapping

- `executor.thought` -> `thinking`
- `executor.plan` -> `planning`
- `executor.output` -> `responding`
- `tool.*` -> `tool`
- `approval.required` -> `approval`
- `approval.approved` -> `approval-sent`
- `task.completed` -> `completed`
- `task.failed`, `executor.failed` -> `failed`
- `executor.*` -> `routing`
- `agent.*` -> `agent`
- everything else -> `step`

## Output Aggregation

Adjacent `executor.output` events are merged into one response block. This prevents every streamed token or text delta from appearing as a separate timeline row.

The raw events remain stored in SQLite. The aggregation is a frontend view-model only.
