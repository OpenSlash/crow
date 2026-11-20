# Crow Rectangular Notch Island Brief

This brief defines a more rectangular Mac notch-fused Crow Island.

Unlike the organic capsule storyboard, this version should feel more practical and implementable:

```text
notch anchor -> compact rectangular tab -> rectangular dropdown panel -> approval/action panel
```

## 1. Design Intent

Create a rectangular version of Crow Island that still visually connects to the Mac notch.

The design should be:

- More utilitarian.
- Easier to implement with SwiftUI/AppKit.
- Closer to a compact command/control panel.
- Still clearly emerging from the notch.
- Less organic and less blob-like than the capsule version.

## 2. Shape Language

### Compact Tab

```text
Shape: short rounded rectangle attached to notch
Width: 180-260 px
Height: 34-42 px
Corner radius: 10-14 px
Material: black graphite
```

### Expanded Panel

```text
Shape: rectangular dropdown panel with 12-18 px radius
Width: 480-680 px
Height: 160-280 px
Top edge visually fused to notch through a centered rectangular neck
```

### Approval Panel

```text
Shape: wider rounded rectangle, amber accent bar or border
Width: 560-760 px
Height: 220-320 px
Layout: header, body preview, button row
```

## 3. Image Generation Prompt

Use case: ui-mockup

Asset type: rectangular macOS notch-fused assistant control panel design for Crow

Primary request:

Create a high-fidelity UI design reference for a rectangular version of Crow Island. It is a Mac notch-fused AI assistant control panel that emerges from the MacBook notch, but uses precise rounded rectangles instead of organic capsules. The design should show a compact rectangular tab attached to the notch and expanded rectangular dropdown panels for running and approval states.

Scene/backdrop:

A realistic MacBook top-screen crop with a visible black notch and macOS menu bar. A blurred Crow task console sits in the background. The foreground focuses on rectangular Crow Island variants connected to the notch.

Subject:

Show four concrete rectangular notch island forms:

1. Compact rectangular tab attached directly to the bottom of the notch, black graphite, crow mark and "Crow".
2. Running rectangular dropdown panel connected to the notch with a short centered neck. Text: "Research AI desktop assistants", "Extracting sources...", teal progress bar, small activity ring.
3. Approval rectangular dropdown panel connected to the notch, amber accent bar on the left or top, text: "Approval Required", "Level 2 - Reversible", "Create Markdown research report", buttons "Approve", "Reject", "Open Task".
4. Completed compact rectangular tab, green accent, text: "Research report ready", button "Open".

Style/medium:

High-fidelity native macOS UI mockup. Practical, precise, refined, and implementation-friendly. It should feel like a compact system control panel, not a chat widget. Use clean alignment, crisp typography, subtle borders, and restrained shadows.

Composition/framing:

16:9 landscape product design board. Show the notch clearly at the top center. Place the approval rectangular panel as the main focus. Keep the panels visually attached to the notch. Use minimal labels if needed, but do not make it a heavy infographic.

Lighting/mood:

Bright neutral macOS environment, calm and focused. Subtle depth, no dramatic lighting.

Color palette:

Black graphite anchor, off-white translucent panel, muted teal for running, amber for approval, green for completed. Avoid purple gradients and avoid dark cyberpunk styling.

Materials/textures:

Native macOS translucent panel material, subtle graphite header, thin borders, soft shadow. Rectangular shapes with modest corner radii. No blob-like organic curves.

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

- Use rectangular dropdown panels, not pill-only capsules.
- Still make the notch connection visually obvious.
- Do not leave a visible gap between notch and compact tab.
- Expanded panels should connect through a simple rectangular neck or top bridge.
- Do not show full dashboard as foreground.
- Do not use chat bubbles.
- Do not use humanoid assistant.
- No copyrighted product logos.
- No watermark.
- Keep labels readable and aligned.

Avoid:

- Organic blob shape.
- Detached notification card.
- Purple SaaS gradients.
- Dark cyberpunk UI.
- Large mascot.
- Incoherent small text.

## 4. Suggested Output

```text
output/imagegen/crow-notch-island-rectangular.png
```

Suggested model settings:

```text
model: gpt-image-2
quality: medium
size: 1536x1024
output format: png
```
