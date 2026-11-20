# Crow Island Visual Brief

This brief defines the Open Vibe Island-inspired visual form for Crow.

The island is not the full product. It is Crow's persistent ambient control surface:

```text
idle -> listening -> thinking -> running -> waiting approval -> completed -> failed
```

It should make Crow feel present without turning into a large dashboard.

## 1. Role

Crow Island is the lightweight desktop surface that answers:

- Is Crow active?
- What is Crow doing now?
- Does Crow need me?
- Can I jump back into the task?

It should not replace the main task console.

## 2. Visual Principles

- Ambient, not noisy.
- Compact by default.
- Expands only when useful.
- Strong state clarity.
- Approval states must be impossible to miss.
- Native macOS feeling, but distinct enough to be ownable.
- No cyberpunk assistant avatar.
- No chat bubble layout.

## 3. Core States

### Idle

```text
Small crow mark + "Crow"
No task text unless hovered or clicked.
```

### Listening

```text
Microphone waveform
"Listening..."
Subtle teal pulse
```

### Thinking

```text
Crow mark + animated dots
"Planning task..."
```

### Running

```text
Task title
Current step
Progress or activity indicator
Small agent/tool icon
```

Example:

```text
Research AI desktop assistants
Extracting sources...
```

### Waiting Approval

```text
Amber approval state
"Approval Required"
Risk level
Approve / Reject compact actions
```

Example:

```text
Approval Required
Level 2 - Reversible
[Approve] [Reject]
```

### Completed

```text
Green completion state
"Research report ready"
[Open]
```

### Failed

```text
Red failure state
"Task failed"
[Details]
```

## 4. Size Modes

### Compact

Persistent form.

```text
Width: 180-260 px
Height: 36-44 px
```

Content:

- Crow mark
- State label
- Small activity indicator

### Expanded

Appears on click, hover, shortcut, or when approval is required.

```text
Width: 420-560 px
Height: 120-220 px
```

Content:

- Task title
- Current state
- One or two action buttons
- Mini timeline or step list

### Alert

Approval-first mode.

```text
Width: 480-620 px
Height: 160-240 px
```

Content:

- Approval required title
- Risk level
- Proposed action preview
- Approve / Reject buttons

## 5. Prompt For Image Generation

Use case: ui-mockup

Asset type: desktop native floating island visual system for Crow MVP

Primary request:

Create a high-fidelity macOS desktop UI design reference for "Crow Island", a Dynamic Island-inspired floating control surface for Crow, a personal AI execution assistant. Show multiple island states in one coherent presentation: compact idle, listening, running task, waiting approval expanded state, completed state, and failed state. The island should sit near the top center of a macOS desktop, above a lightly blurred or simplified Crow task console in the background.

Scene/backdrop:

A macOS desktop with a subtle Crow main window blurred in the background. The foreground focuses on several variations of the Crow Island floating capsule, arranged clearly as a visual system sheet. Include a top-center island position hint.

Subject:

Crow Island visual states:

1. Compact idle: small black crow mark, "Crow".
2. Listening: waveform, "Listening...".
3. Running: "Research AI desktop assistants", "Extracting sources...", progress indicator.
4. Waiting approval: expanded amber state with "Approval Required", "Level 2 - Reversible", compact "Approve" and "Reject" buttons.
5. Completed: green state with "Research report ready", "Open".
6. Failed: red state with "Task failed", "Details".

Style/medium:

High-fidelity product UI mockup, native macOS floating surface, elegant operational design. It should feel like a polished system-level assistant control, not a chat widget. Use precise spacing, crisp typography, subtle depth, and clear state hierarchy.

Composition/framing:

16:9 landscape visual system sheet. Place the most important waiting approval expanded island in the center. Place compact states around it. Keep all labels legible. No marketing hero layout.

Lighting/mood:

Calm, refined, focused. Bright neutral macOS environment with subtle shadow under floating capsules.

Color palette:

Graphite, off-white, muted teal for active/running, amber for approval, green for completed, red for failed. Avoid purple gradients and avoid dark cyberpunk styling.

Materials/textures:

Native translucent macOS-like floating capsule surfaces, subtle border, soft but restrained shadow, no heavy glassmorphism.

Text:

Use these exact visible labels where possible:

- "Crow"
- "Listening..."
- "Research AI desktop assistants"
- "Extracting sources..."
- "Approval Required"
- "Level 2 - Reversible"
- "Approve"
- "Reject"
- "Research report ready"
- "Open"
- "Task failed"
- "Details"

Constraints:

- The island must look compact and system-level, not like a full dashboard.
- Approval state must be the clearest expanded state.
- Do not use chat bubbles.
- Do not use a humanoid assistant.
- Do not use copyrighted product logos.
- No watermark.
- Keep text readable and avoid overlapping UI.

Avoid:

- Purple SaaS gradient default.
- Dark cyberpunk look.
- Large mascot illustration.
- Generic chatbot widget.
- Incoherent tiny text.
- Overdecorated cards.

## 6. Suggested Output

```text
output/imagegen/crow-island-visual-system.png
```

Suggested model settings:

```text
model: gpt-image-2
quality: medium
size: 1536x1024
output format: png
```
