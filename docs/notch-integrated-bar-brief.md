# Crow Notch Integrated Bar Brief

This brief defines the tighter reference direction from the provided image:

```text
top screen edge -> black integrated bar -> icon/status inside -> expands from the same bar
```

The key difference from previous versions:

- It should not look like a floating panel below the notch.
- It should not look like an organic blob.
- It should look like a black rectangular status bar fused into the top edge of the screen.
- The compact state should be almost flush with the menu bar/top safe area.

## 1. Reference Observation

The reference image shows:

- A black horizontal rounded rectangle fused into the top center.
- The bar touches the top edge visually.
- A small app icon sits on the left inside the bar.
- A small audio/status meter sits on the right inside the bar.
- The shape is compact, rectangular, and system-level.
- The background remains visible and uncluttered.

Crow should use this form as its compact state.

## 2. Product Shape

### Compact Integrated Bar

```text
Position: top center, flush with top edge / notch area
Shape: black rounded rectangle, mostly horizontal
Width: 220-340 px
Height: 34-46 px
Corner radius: 8-12 px
Content left: Crow app icon / crow mark
Content center: optional task/state label
Content right: activity bars / mic waveform / status dots
```

### Running Expansion

```text
The compact bar stays attached to the top edge.
A rectangular panel drops down from the same black bar.
The top edge of the panel visually shares the black bar as its header.
```

### Approval Expansion

```text
The top integrated bar becomes the header of the approval panel.
The panel expands downward with a rectangular body.
Approval buttons sit in the lower area.
Amber accent is used, but the top anchor remains black.
```

## 3. Image Generation Prompt

Use case: ui-mockup

Asset type: macOS top-edge integrated AI status bar design for Crow

Primary request:

Create a high-fidelity UI design reference for Crow's notch-integrated top bar. The compact state should look like a black rectangular status bar fused into the top center edge of a Mac screen, similar to a system-level island embedded in the menu bar area. It should contain a small Crow icon on the left and an activity meter on the right. Show how this compact top bar expands downward into running and approval panels while remaining physically connected to the same top-edge black bar.

Scene/backdrop:

A Mac desktop screen with a sky or soft neutral wallpaper and a subtle macOS menu bar. The Crow surface is at the top center, flush with the top edge. The design should focus on the black integrated top bar and its expanded states. Keep the background clean and secondary.

Subject:

Show three concrete forms:

1. Compact integrated bar: black rounded rectangular bar touching the top edge, small Crow icon on the left, "Crow" or short status text in the center, small vertical activity bars on the right.
2. Running expanded state: the same black top bar remains flush with the top edge, and a rectangular dropdown body expands downward. Text: "Research AI desktop assistants", "Extracting sources...", teal progress bar.
3. Approval expanded state: the same top bar becomes the header of a larger rectangular approval panel. Text: "Approval Required", "Level 2 - Reversible", "Create Markdown research report", buttons "Approve", "Reject", "Open Task".

Style/medium:

High-fidelity native macOS UI mockup. Precise, compact, rectangular, implementation-friendly. It should feel like a system status surface, not a floating notification card and not a chat widget.

Composition/framing:

16:9 landscape. Use a large top-screen crop. The compact integrated bar should be the clearest visual. Place the expanded running and approval states below or as sequential variants, but keep their top edges visibly connected to the same top-center bar. Avoid a heavy diagram style.

Lighting/mood:

Bright clean desktop environment. Calm, focused, system-level.

Color palette:

Black graphite top bar, off-white or dark translucent dropdown body, muted teal for running, amber for approval. Avoid purple gradients and dark cyberpunk styling.

Materials/textures:

Matte black top bar with subtle radius and shadow. Dropdown panels use restrained macOS translucent material, thin border, modest corner radius. No organic blob shape.

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

Constraints:

- The compact bar must be flush with the top edge, not detached below the notch.
- The bar should look like one integrated black status strip.
- The left icon and right activity meter should sit inside the black strip.
- Expanded states must grow from the same top strip.
- Use rectangular forms, not organic blob shapes.
- Do not make it a full dashboard.
- Do not use chat bubbles.
- No watermark.
- Keep text readable.

Avoid:

- Floating cards with a visible gap from the top edge.
- Large rounded capsules detached from the menu bar.
- Organic liquid shapes.
- Purple SaaS gradients.
- Mascot character.
- Tiny unreadable text.

## 4. Suggested Output

```text
output/imagegen/crow-notch-integrated-bar.png
```

Suggested model settings:

```text
model: gpt-image-2
quality: medium
size: 1536x1024
output format: png
```
