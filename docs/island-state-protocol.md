# Island State Protocol

Crow Desktop writes the latest task state to:

```text
~/Library/Application Support/Crow/island-state.json
```

The native macOS Island reads this file and renders the notch UI.

## Fields

`status`
: Storage-level task status: `idle`, `running`, `waiting_approval`, `completed`, `failed`, `cancelled`.

`phase`
: Execution-level display phase. This is more specific than `status` and should drive Island motion and labels.

Supported phases:

- `idle`
- `starting`
- `thinking`
- `planning`
- `responding`
- `speaking`
- `tool`
- `running`
- `approval`
- `completed`
- `failed`

`title`
: Latest event title or approval action.

`message`
: Latest event message or approval title.

`action`
: Short UI verb for the Island, for example `Thinking`, `Using tool`, `Approval required`.

`detail`
: Supporting text for expanded Island surfaces.

`executor`
: Executor identity when known, for example `codex` or `agent`.

`kind`
: Crow task kind: `code`, `agent`, `research`, `email`, `browser`, `general`.

`pendingApprovals`
: Number of pending approvals across Crow.

`approvalId`
: Current pending approval ID. Present when `phase` is `approval`.

`approvalTitle`
: Approval title shown in the Island approval surface.

`approvalAction`
: Proposed action that the user is approving or rejecting.

`approvalPreview`
: Optional preview text or path for the pending approval.

`approvalRisk`
: Numeric risk level for the pending approval.

## Island Actions

The native Island can send lightweight actions back to Crow Desktop by writing:

```text
~/Library/Application Support/Crow/island-action.json
```

Approval action payload:

```json
{
  "id": "island_action_1780000000000",
  "type": "approval.approve",
  "approvalId": "approval_task_...",
  "createdAt": "2026-06-10T12:00:00Z"
}
```

Supported action types:

- `approval.approve`
- `approval.reject`

Crow Desktop polls this file and applies the decision through the same approval flow used by the main console.

## Executor Mapping

Executor events are normalized before writing Island state:

- `executor.thought` -> `thinking`
- `executor.plan` -> `planning`
- `executor.output` -> `responding`
- `voice.output.started` -> `speaking`
- `voice.output.segment` -> `speaking`
- `tool.started` -> `tool`
- `approval.required` -> `approval`
- `task.completed` -> `completed`
- `task.failed` -> `failed`

This keeps native UI simple: it does not need to understand Codex protocol details.
