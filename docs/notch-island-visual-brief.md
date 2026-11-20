# Crow Notch Island Visual Brief

This brief defines the specific Mac notch pop-out form for Crow Island.

The previous island visual system shows the states. This brief focuses on the exact physical behavior:

```text
Mac notch anchor -> compact island -> downward expanded panel -> approval/action state -> return to compact
```

## 1. Product Role

Crow Notch Island is the persistent top-center surface for Crow on Mac.

It should feel like it emerges from the Mac notch or top menu-bar center, then expands downward when Crow needs attention.

Primary use cases:

- Ambient task status.
- Voice listening indicator.
- Running task progress.
- Approval request.
- Quick jump back to main task console.

It is not a full dashboard and should not show the entire task timeline.

## 2. Physical Form

### Anchor

The island is visually attached to the Mac notch / top-center screen edge.

Default location:

```text
Top center, directly below or visually connected to the Mac notch.
```

### Collapsed Form

```text
Shape: rounded black capsule integrated with notch
Size: 170-240 px wide, 32-40 px high
Content: crow mark, current state, tiny activity indicator
```

### Expanded Form

```text
Shape: rounded rectangular panel growing downward from notch
Size: 460-620 px wide, 150-260 px high
Content: task title, current step, progress, action buttons
```

### Approval Form

```text
Shape: amber-accent expanded panel
Size: 520-680 px wide, 190-280 px high
Content: approval title, risk level, action preview, approve/reject buttons
```

## 3. Required States

### Compact Idle

```text
Crow
small crow mark
```

### Listening Pop-Out

```text
Listening...
waveform
```

### Running Pop-Out

```text
Research AI desktop assistants
Extracting sources...
progress bar
```

### Approval Pop-Out

```text
Approval Required
Level 2 - Reversible
Crow wants to create a Markdown research report.
Approve
Reject
Open Task
```

### Completed Pop-Out

```text
Research report ready
Open
```

## 4. Image Generation Prompt

Use case: ui-mockup

Asset type: macOS notch pop-out product interaction design for Crow MVP

Primary request:

Create a high-fidelity UI design reference showing Crow Island emerging from the MacBook notch. The image should clearly show the specific physical shape and interaction: a small black capsule anchored to the notch at the top center, expanding downward into a larger rounded panel for task status and approval. This is a macOS system-level floating assistant surface for Crow, a personal AI execution assistant.

Scene/backdrop:

A realistic MacBook desktop screen crop with a visible top-center notch and macOS menu bar. The background should be a softly blurred Crow task console, but the focus must be the notch-attached island. Show the island as if it is connected to or growing out of the notch.

Subject:

Show three concrete notch island forms in one coherent product design board:

1. Collapsed notch capsule attached to the Mac notch, black rounded pill, crow mark and "Crow".
2. Running expanded pop-out growing downward from the notch, with "Research AI desktop assistants", "Extracting sources...", a teal progress bar, and a small activity ring.
3. Approval expanded pop-out growing downward from the notch, amber-accented, with "Approval Required", "Level 2 - Reversible", "Create Markdown research report", and buttons "Approve", "Reject", "Open Task".

Also include a small completed state near the bottom as a compact green capsule with "Research report ready" and "Open".

Style/medium:

High-fidelity native macOS UI mockup, polished product interaction design. The island should feel like a system-level surface similar in spirit to Dynamic Island, but designed for Mac. Use refined spacing, crisp typography, realistic shadows, and translucent native materials.

Composition/framing:

16:9 landscape image. Top third should clearly show the Mac notch and collapsed island attached to it. Center should show the expanded running and approval forms, with the approval pop-out as the main focus. Use subtle arrows or ghosted transition silhouettes only if helpful, but do not make it a diagram-heavy infographic.

Lighting/mood:

Bright neutral macOS environment, calm and focused. Subtle shadow under the pop-out panels. No dark cyberpunk theme.

Color palette:

Black graphite capsule, off-white translucent expanded panel, muted teal for running, amber for approval, green for completed. Avoid purple gradients and avoid one-note dark blue palettes.

Materials/textures:

Native macOS glass-like surface with restraint, subtle blur, soft border, realistic floating shadow. Keep it premium but not flashy.

Text:

Use these exact visible labels where possible:

- "Crow"
- "Research AI desktop assistants"
- "Extracting sources..."
- "Approval Required"
- "Level 2 - Reversible"
- "Create Markdown research report"
- "Approve"
- "Reject"
- "Open Task"
- "Research report ready"
- "Open"

Constraints:

- The design must clearly look like it pops out from the Mac notch/top center, not just random floating cards.
- The notch anchor must be visually obvious.
- The expanded approval panel must be physically connected to the top island shape.
- Do not show a full dashboard as the foreground.
- Do not use chat bubbles.
- Do not use a humanoid assistant.
- No copyrighted product logos.
- No watermark.
- Keep text legible and avoid overlapping UI.

Avoid:

- Generic floating notification cards unrelated to the notch.
- Full-screen dashboard focus.
- Purple SaaS gradients.
- Dark cyberpunk assistant.
- Large mascot illustration.
- Tiny unreadable UI text.

## 5. Suggested Output

```text
output/imagegen/crow-notch-island-popout.png
```

Suggested model settings:

```text
model: gpt-image-2
quality: medium
size: 1536x1024
output format: png
```
