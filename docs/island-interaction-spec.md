# Crow Island Interaction Spec

Crow Island V1 uses a top-edge integrated black bar with downward rectangular expansion.

Final V1 direction:

```text
Top-edge integrated black Crow Bar
-> downward rectangular panel expansion
-> compact bar remains as shared header
```

This supersedes the earlier capsule/blob explorations.

## 1. Product Role

Crow Island is Crow's ambient desktop control surface.

It answers:

- What is Crow doing?
- Does Crow need approval?
- Can I quickly open the task?
- Can I control or interrupt the current action?

It is not:

- A full dashboard.
- A chat window.
- A replacement for the main task console.
- A detached notification card.

## 2. Final Visual Direction

### V1 Shape

```text
Top-edge integrated black bar + rectangular dropdown body
```

The compact state should look like a black system status strip embedded in the top center of the screen.

The expanded state should look like the body of that strip extending downward.

### Important Visual Rules

- The bar is flush with the top edge.
- There is no visible gap between top edge and bar.
- The bar visually separates left app menus and right system status items.
- The top edge has no shadow.
- Shadow appears only under the expanded body.
- Expanded panels share the same top black bar as their header.
- The panel body grows from the bottom of the bar.
- Use rectangular forms with modest corner radii.
- Do not use organic blob or liquid shapes for V1.

### Reference Assets

Primary V1 direction:

```text
output/imagegen/crow-notch-integrated-bar.png
```

Feature states:

```text
output/imagegen/crow-island-voice.png
output/imagegen/crow-island-task-progress.png
output/imagegen/crow-island-approval.png
output/imagegen/crow-island-notification.png
output/imagegen/crow-island-preview.png
```

Exploration only:

```text
output/imagegen/crow-notch-island-motion-storyboard.png
output/imagegen/crow-notch-island-rectangular.png
output/imagegen/crow-island-visual-system.png
```

## 3. Layout And Geometry

### Screen Position

```text
Anchor: top center
Y: 0 px from top screen edge
Horizontal: centered within visible display bounds
```

On MacBook notch screens, the island should visually align with the notch/safe-area center.

On non-notch screens, it should still appear as a top-center integrated status bar.

### Compact Bar

Recommended geometry:

```text
width: 300-480 px
height: 44-56 px
corner radius: 0 px top corners or visually flush top
bottom corner radius: 10-16 px
top shadow: none
bottom shadow: subtle
```

Content layout:

```text
left: Crow mark
center: state label or task label
right: activity meter / waveform / status icon
```

Example:

```text
[crow mark]        Crow        [activity bars]
```

### Expanded Panel

Recommended geometry:

```text
width: 480-720 px
height: 160-320 px
corner radius: 12-18 px on bottom corners
top corners: visually joined to compact bar
top edge: same x/y as compact bar header
```

The compact bar remains the panel header. The body expands below it.

### Approval Panel

Recommended geometry:

```text
width: 560-760 px
height: 230-340 px
accent: amber
button row: bottom
```

Approval should be the largest and most attention-demanding state.

## 4. States

### Idle

Purpose:

- Crow is available.
- No active user-visible task.

Compact bar:

```text
left: Crow mark
center: Crow
right: idle dot or empty
```

Click:

- Open command input in main Crow window.

### Listening

Purpose:

- User is speaking.

Compact bar:

```text
left: Crow mark
center: Listening...
right: waveform bars
```

Expanded body:

- Optional in V1.
- If expanded, show transcript and controls.

Controls:

```text
Stop
Send
Mute
```

### Thinking

Purpose:

- Crow is planning or waiting for model response.

Compact bar:

```text
left: Crow mark
center: Planning...
right: animated dots/bars
```

No expanded body required.

### Running

Purpose:

- Crow is executing a task.

Compact bar:

```text
left: Crow mark
center: Running
right: activity meter
```

Expanded body:

```text
Task title
Current step
Progress if available
Mini step list
Open Task
Pause
Cancel
```

Example:

```text
Research AI desktop assistants
Extracting sources...
68%

Search completed
Sources extracting
Summarizing next

[Open Task] [Pause] [Cancel]
```

### Waiting Approval

Purpose:

- Crow cannot continue without user approval.

Compact bar:

```text
left: Crow mark
center: Approval Required
right: amber activity bars
```

Expanded body:

```text
Approval Required
Level 2 - Reversible
Create Markdown research report
Preview path or action details
Crow will not continue without your approval.

[Approve] [Reject] [Open Task]
```

Rules:

- Auto-expand immediately.
- Do not auto-dismiss.
- Reject is as visible as Approve.
- Approval state can trigger notification if app is not focused.

### Completed

Purpose:

- Task finished successfully.

Compact bar:

```text
left: success icon or Crow mark
center: Report ready / Task complete
right: Open
```

Expanded body:

- Optional.
- If clicked, show preview or open main task.

Timeout:

- Collapse to idle after 2-4 seconds unless user hovers/clicks.

### Failed

Purpose:

- Task failed or was rejected/cancelled.

Compact bar:

```text
left: error icon
center: Task failed
right: Details
```

Expanded body:

```text
Failure reason
Last completed step
Open Task
Dismiss
```

Rules:

- Do not auto-hide immediately.
- Stay until user opens details, dismisses, or timeout policy is reached.

### Preview

Purpose:

- Quick look at generated artifact or output.

Compact bar:

```text
left: Crow mark
center: Preview
right: document/activity icon
```

Expanded body:

```text
Research Report
3 bullet summary
Sources
Artifact row

[Open Markdown] [Copy Summary] [Save]
```

## 5. State Transitions

Primary flow:

```text
idle
-> listening
-> thinking
-> running
-> waitingApproval
-> running
-> completed
-> idle
```

Failure flow:

```text
running
-> failed
```

Reject approval flow:

```text
waitingApproval
-> failed(permission_rejected)
```

Preview flow:

```text
completed
-> preview
-> idle
```

## 6. Motion

### Compact To Expanded

Motion:

```text
bar stays fixed at top edge
body expands downward from bar bottom
body opacity fades in
content slides down 6-10 px
shadow increases under body
```

Timing:

```text
container expansion: 180-260ms
content fade/slide: 90-140ms, delayed 40-80ms
button reveal: 60-90ms stagger
```

Easing:

```text
container: easeOutCubic or spring with very low overshoot
content: easeOut
collapse: easeInOutCubic
```

### Expanded To Compact

Motion:

```text
content fades out
body height collapses upward into bar
bar remains fixed
shadow fades
```

Timing:

```text
content fade: 80ms
body collapse: 160-220ms
```

### Approval Transition

Motion:

```text
running panel body expands slightly
amber accent fades in
approval content crossfades
buttons slide in last
```

Approval transition should be noticeable but not alarming.

## 7. Interaction Rules

### Click

Compact idle:

- Open main Crow window and focus command input.

Compact running:

- Expand running panel.

Compact completed:

- Open result preview.

Compact failed:

- Expand failed detail.

Approval:

- Already expanded.
- Buttons execute directly.

### Hover

Compact:

- Slightly reveal state or increase activity visibility.
- Do not fully expand unless explicitly configured.

Expanded:

- Keep open.

### Keyboard

Global shortcut:

- If approval pending: expand approval panel.
- Else open main Crow command input.

Escape:

- Collapse expanded non-approval panel.
- Do not dismiss approval.

### Notifications

Trigger notifications for:

- Approval required.
- Task completed.
- Task failed.

Click notification:

- Open matching island panel or main task console.

## 8. Implementation Boundary

### Owner

The island should be implemented by the macOS native layer:

```text
SwiftUI/AppKit helper
```

The main Wails/React app should not own the island rendering.

### Runtime Input

Go runtime sends island state view models through platform adapter.

Example:

```go
type IslandState string

const (
    IslandIdle IslandState = "idle"
    IslandListening IslandState = "listening"
    IslandThinking IslandState = "thinking"
    IslandRunning IslandState = "running"
    IslandWaitingApproval IslandState = "waiting_approval"
    IslandCompleted IslandState = "completed"
    IslandFailed IslandState = "failed"
    IslandPreview IslandState = "preview"
)
```

```go
type IslandViewModel struct {
    State       IslandState       `json:"state"`
    TaskID      string            `json:"taskId,omitempty"`
    Title       string            `json:"title,omitempty"`
    Subtitle    string            `json:"subtitle,omitempty"`
    Progress    *float64          `json:"progress,omitempty"`
    Accent      string            `json:"accent,omitempty"`
    Actions     []IslandAction    `json:"actions,omitempty"`
    Metadata    map[string]string `json:"metadata,omitempty"`
}
```

### Native Surface

Recommended:

```text
NSPanel
borderless
transparent background
top-center screen positioning
always above normal app windows
does not activate app unless action requires it
SwiftUI root view
```

### Shape Implementation

Use one composed native view:

```text
IslandRoot
├── BarHeader
└── ExpandableBody
```

Do not implement the expanded body as a visually detached second card.

### Visual Implementation Notes

- Header and body must align perfectly.
- Header top must be flush to screen top.
- Header can mask its top corners to appear integrated.
- Body only has bottom rounded corners.
- Shadow should apply to body/downward area, not top edge.
- Use vibrancy/material carefully; black header should remain legible.

## 9. V1 Scope

V1 must include:

- Idle compact bar.
- Running expanded panel.
- Waiting approval expanded panel.
- Completed compact state.
- Failed compact state.
- Open Task action.
- Approve/Reject actions.

V1.1 can include:

- Voice listening expanded panel.
- Preview expanded panel.
- Notification compact state.
- Progress mini-step list.

V2 can include:

- Rich voice conversation.
- Multi-task switching.
- Inline source preview.
- User-customizable position.
- Always-on wake word state.

## 10. Design Decisions

### Accepted

- Top-edge integrated black bar.
- Rectangular dropdown body.
- Approval as strongest state.
- Mac native helper owns island UI.
- Main Crow console remains separate.

### Rejected For V1

- Organic blob expansion.
- Detached floating notification card.
- Full dashboard inside island.
- Chat bubble island.
- Mascot/character assistant.
- Bottom or side island placement.

## 11. Acceptance Criteria

The island implementation is acceptable when:

- It looks visually integrated with the top center screen edge.
- It does not look like a detached card.
- Running state can be understood at a glance.
- Approval state is immediately visible and actionable.
- Expanded body grows from the black bar.
- Main Crow console opens from island actions.
- State updates are driven by runtime events.

It is not acceptable if:

- There is a visible gap between bar and top edge.
- Expanded panel appears as a separate window.
- Approval can be missed.
- Text overlaps menu bar items.
- The island blocks important system controls on common screen sizes.
- It requires the Wails webview to be open to render.
