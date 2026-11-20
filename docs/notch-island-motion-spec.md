# Crow Notch Island Motion Spec

Crow Island should not feel like a floating notification placed under the notch.

It should feel physically fused with the Mac notch:

```text
notch -> fused capsule -> elastic downward expansion -> task panel -> collapse back into notch
```

## 1. Core Motion Principle

The island is visually part of the black notch mass.

When idle, Crow's capsule should share the notch color, radius, and visual weight. The user should perceive it as an extension of the notch, not a detached window.

When active, the shape expands from the notch downward, as if the notch has become a living control surface.

## 2. Physical States

### State A: Fused Idle

Visual:

- Black notch at top center.
- Crow capsule is attached to the bottom of the notch.
- No visible gap between notch and capsule.
- Same black material as notch.
- Small crow mark and optional "Crow" label.

Behavior:

- Minimal presence.
- Subtle breathing or tiny activity dot only when enabled.

### State B: Wake / Listening

Transition:

```text
notch black mass subtly widens
bottom edge rounds downward
waveform fades in
```

Visual:

- Capsule remains fused with notch.
- Waveform appears inside the black surface.
- Teal accent pulse can appear, but the base remains black.

### State C: Thinking

Transition:

```text
listening waveform compresses into activity dots
capsule grows slightly wider
```

Visual:

- "Planning task..."
- Small activity dots.
- No large panel yet.

### State D: Running Expanded

Transition:

```text
black notch surface stretches downward
panel grows from top center
content fades/slides in after shape expansion
```

Visual:

- Expanded panel is physically connected to notch by a black neck/stem.
- Main body can use dark translucent graphite or light translucent macOS material.
- Running accent uses teal.
- Shows task title, current step, progress.

### State E: Approval Expanded

Transition:

```text
running panel expands wider and warmer
amber border/accent fades in
approval content replaces running content
buttons slide in last
```

Visual:

- Approval panel remains connected to notch.
- Amber accent is strong.
- Approve and Reject buttons are obvious.
- Open Task is secondary.

### State F: Complete / Collapse

Transition:

```text
panel contracts upward
content fades out
green compact confirmation appears
confirmation shrinks into notch
```

Visual:

- Compact green success capsule may appear for 2-4 seconds.
- Then returns to fused idle.

### State G: Failed

Transition:

```text
panel snaps to compact alert
red accent appears
details button appears
```

Visual:

- Red compact panel.
- "Task failed"
- Details button.

## 3. Motion Timing

Recommended timings:

```text
idle -> listening: 180ms
listening -> thinking: 160ms
thinking -> running expanded: 260ms
running -> approval expanded: 220ms
approval decision -> running: 180ms
running -> completed compact: 240ms
completed compact -> idle: 300ms after 2-4s dwell
failed alert: 180ms
```

Easing:

```text
expand: spring-like, soft overshoot
collapse: cubic ease-in-out
content fade: 80-120ms after container starts moving
button reveal: 80ms stagger
```

## 4. Geometry

### Notch Fusion

Important:

- No visible gap between notch and island in fused states.
- Use same fill color as notch for connector/neck.
- Connector should be centered.
- Expanded panel should appear to grow from this connector.

### Compact Geometry

```text
width: 160-260 px
height: 34-44 px
corner radius: 18-22 px
anchor: top center, bottom edge of notch
```

### Expanded Geometry

```text
width: 460-680 px
height: 150-280 px
corner radius: 28-36 px
connector width: 110-180 px
connector height: 18-34 px
```

### Approval Geometry

```text
width: 560-720 px
height: 210-300 px
primary button area: bottom row
```

## 5. Interaction Rules

Click compact island:

- Open expanded state for current task.
- If no task, open command input.

Click approval island:

- Approval card stays open.
- Approve / Reject act immediately.
- Open Task opens main console.

Hover:

- Compact state can expand slightly.
- Do not fully open approval on hover; approval should open automatically.

Shortcut:

- Global shortcut focuses command.
- If approval is pending, shortcut opens approval island first.

Timeouts:

- Completed compact state collapses after 2-4 seconds.
- Failed state remains until dismissed or task opened.
- Approval state never auto-dismisses.

## 6. Implementation Notes

SwiftUI/AppKit should own this surface.

Recommended implementation:

```text
NSPanel
├── transparent background
├── top-center positioning
├── ignores normal app window stacking where appropriate
└── SwiftUI island view
```

Shape implementation:

- Build a custom fused shape instead of stacking two separate rounded rectangles.
- Use a notch connector shape for expanded states.
- Animate frame and path together.
- Animate content opacity separately from container geometry.

State model:

```swift
enum IslandState {
    case idle
    case listening
    case thinking
    case running(TaskIslandViewModel)
    case waitingApproval(ApprovalIslandViewModel)
    case completed(CompletedIslandViewModel)
    case failed(FailedIslandViewModel)
}
```

## 7. Design Acceptance

The island design is correct when:

- It visually belongs to the Mac notch.
- Expansion appears to originate from the notch.
- Approval state cannot be missed.
- The main console is clearly separate from the island.
- The island can collapse back into a small fused notch extension.

The design is wrong when:

- It looks like a floating card under the menu bar.
- There is a visible detached gap from the notch.
- It looks like a generic notification banner.
- It shows too much dashboard content.
- Approval buttons are unclear or secondary.
