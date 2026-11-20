# Crow MVP Design Image Brief

This brief is for generating the first Crow product design reference image with `gpt-image-2`.

## Core Function Check

The current MVP documentation defines Crow as a desktop command center for AI-executed tasks.

The first design image should cover the core product loop:

```text
Command -> Task -> Timeline -> Tool/Agent -> Approval -> Artifact -> History
```

Core surfaces to show:

- Command input at the top.
- Task list on the left.
- Active task detail in the main panel.
- Execution timeline as the main trust surface.
- Approval card for sensitive actions.
- Agent status card.
- Research result with sources and Markdown artifact.
- macOS-style menu bar presence.

The design should not look like a chat app. It should look like an operational task console.

## Image Generation Prompt

Use case: ui-mockup

Asset type: desktop application product design reference for Crow MVP

Primary request:

Create a polished desktop UI mockup for "Crow", a macOS-first personal AI execution hub. The screen should show the main task console, not a marketing page. Crow helps users create, observe, and control AI-executed tasks.

Scene/backdrop:

A single macOS desktop app window centered on a clean neutral desktop background. Include a subtle macOS menu bar presence or small menu bar icon hint, but keep the focus on the main app window.

Subject:

The Crow MVP main console. The interface has:

- A top command input for creating tasks.
- A left sidebar task list with filters: All, Running, Waiting, Completed, Failed.
- A main task detail panel with a visible execution timeline.
- A current active task titled "Research AI desktop assistants".
- Timeline items for search, source extraction, summarization, approval, artifact creation, and completion.
- An approval card that says "Approval Required" and shows a Level 2 reversible action.
- An agent status card showing "Codex: Running checks".
- A research result panel with key findings, source list, and a Markdown artifact card.
- Status pills for Running, Waiting Approval, Completed.

Style/medium:

High-fidelity SaaS/product UI mockup, realistic macOS desktop app, refined but practical. It should feel calm, sharp, operational, and trustworthy. Use crisp typography, clear spacing, and strong information hierarchy.

Composition/framing:

16:9 landscape desktop screenshot, full app window visible, slightly zoomed enough that layout and labels are readable. Two-column app layout: task sidebar on the left, task detail and timeline on the right. Avoid oversized hero sections.

Lighting/mood:

Bright neutral interface with subtle depth. Calm professional mood. No dark cyberpunk theme.

Color palette:

Neutral graphite, off-white panels, muted teal and amber status accents, small black crow brand mark. Avoid purple-dominant gradients and avoid one-note dark blue palettes.

Materials/textures:

Clean native macOS-style surfaces, subtle borders, no heavy glassmorphism, no excessive shadows. Small status badges and timeline markers should be crisp.

Text:

Use these exact visible labels where possible:

- "Crow"
- "Ask Crow to research, run an agent, or organize a task..."
- "Research AI desktop assistants"
- "Waiting Approval"
- "Approval Required"
- "Level 2 - Reversible"
- "Codex: Running checks"
- "Research Report"
- "Open Markdown"
- "Sources"

Constraints:

- The UI must look like an execution console, not a chat interface.
- Do not use chat bubbles as the primary layout.
- Do not create a marketing landing page.
- Do not show fake mobile screens.
- Do not include unrelated characters or mascots.
- Do not use copyrighted product logos.
- No watermark.
- Keep text reasonably legible and UI structure coherent.

Avoid:

- Purple gradient SaaS default look.
- Dark cyberpunk dashboard.
- Overly decorative cards.
- Chatbot-style conversation feed.
- Floating fantasy assistant character.
- Incoherent overlapping text.
- Tiny unreadable UI everywhere.

## Suggested Output

```text
output/imagegen/crow-mvp-console.png
```

Suggested model settings:

```text
model: gpt-image-2
quality: high
size: 2048x1152
output format: png
```
