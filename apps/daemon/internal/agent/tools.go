package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/crow/crow/apps/daemon/internal/llm"
)

// Activity tells the client what Crow is doing right now.
type Activity struct {
	Kind  string `json:"kind"`
	Label string `json:"label"`
}

// Activity kinds shared with the island UI and executor events.
const (
	ActivityThinking      = "thinking"
	ActivityReading       = "reading"
	ActivitySearching     = "searching"
	ActivityWriting       = "writing"
	ActivityRunning       = "running"
	ActivityUsingComputer = "using_computer"
)

// Tool is a function the model can call during a turn.
type Tool interface {
	Spec() llm.Tool
	Activity() Activity
	Run(ctx context.Context, args json.RawMessage) (ToolResult, error)
}

// ToolResult is fed back to the model, unless Handoff ends the turn.
type ToolResult struct {
	Content string
	Handoff *Handoff
}

// Handoff passes the task to a local executor; the client submits it as a task.
type Handoff struct {
	Executor string
	Task     string
}

type useComputer struct{ enabled func() bool }

// UseComputer hands tasks that need the Mac's screen, mouse or keyboard to computer
// use. It is offered only while enabled reports true.
func UseComputer(enabled func() bool) Tool { return useComputer{enabled} }

func (t useComputer) Enabled() bool { return t.enabled == nil || t.enabled() }

func (useComputer) PromptNote() string {
	return "You can see and operate this Mac's screen through use_computer. Never say you cannot see the screen. " +
		"For any request to look at, read, check or describe the screen, a window or an app, or to operate an app's graphical interface, call use_computer. " +
		"Shell commands are not computer use: use run_command or delegate_to_codex instead of typing into Terminal."
}

func (useComputer) Spec() llm.Tool {
	return llm.Tool{
		Name: "use_computer",
		Description: "Look at, read or operate the user's Mac screen: take screenshots, read what apps show, and use the mouse and keyboard. " +
			"Use it whenever the user asks what is on screen or wants something done in an app's graphical interface. Not for shell commands. Never for signing in, passwords or payments.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"task": map[string]any{"type": "string", "description": "A complete, self-contained description of what to do on screen, in the user's language."},
			},
			"required": []string{"task"},
		},
	}
}

func (useComputer) Activity() Activity {
	return Activity{Kind: ActivityUsingComputer, Label: "Using the computer"}
}

func (useComputer) Run(_ context.Context, args json.RawMessage) (ToolResult, error) {
	var in struct {
		Task string `json:"task"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return ToolResult{}, fmt.Errorf("invalid arguments: %w", err)
	}
	if strings.TrimSpace(in.Task) == "" {
		return ToolResult{}, fmt.Errorf("task is required")
	}
	return ToolResult{Handoff: &Handoff{Executor: "computer", Task: strings.TrimSpace(in.Task)}}, nil
}

type openComputerUseSettings struct {
	disabled func() bool
	open     func(context.Context) error
}

// OpenComputerUseSettings is offered while computer use is off: with the user's
// agreement it opens Crow's settings at the Computer use section.
func OpenComputerUseSettings(disabled func() bool, open func(context.Context) error) Tool {
	return openComputerUseSettings{disabled, open}
}

func (t openComputerUseSettings) Enabled() bool { return t.disabled == nil || t.disabled() }

func (openComputerUseSettings) PromptNote() string {
	return "Computer use is turned off, so you cannot see the screen right now. If the user asks you to look at or operate the screen, " +
		"say it is off and offer to open its settings; call open_computer_use_settings after they agree."
}

func (openComputerUseSettings) Spec() llm.Tool {
	return llm.Tool{
		Name: "open_computer_use_settings",
		Description: "Computer use (seeing the screen, mouse and keyboard) is turned off. When the user asks you to look at or operate their screen, " +
			"tell them it is off and offer to open its settings; call this only after they agree. The settings explain the risks and hold the switch and the macOS permissions.",
		Parameters: map[string]any{"type": "object", "properties": map[string]any{}},
	}
}

func (openComputerUseSettings) Activity() Activity {
	return Activity{Kind: ActivityRunning, Label: "Opening settings"}
}

func (t openComputerUseSettings) Run(ctx context.Context, _ json.RawMessage) (ToolResult, error) {
	if err := t.open(ctx); err != nil {
		return ToolResult{}, err
	}
	return ToolResult{Content: "Opened Crow Settings at Computer use. Tell the user to turn on \"Let Crow use this Mac\", grant Screen Recording and Accessibility there, then click Save Settings."}, nil
}

type delegateToCodex struct{ available func() bool }

// DelegateToCodex hands coding, file and terminal work to the Codex executor.
func DelegateToCodex() Tool { return delegateToCodex{} }

// DelegateToCodexIf is DelegateToCodex that, while no code executor is installed,
// tells the model so instead of handing off to nothing.
func DelegateToCodexIf(available func() bool) Tool { return delegateToCodex{available: available} }

func (delegateToCodex) Spec() llm.Tool {
	return llm.Tool{
		Name: "delegate_to_codex",
		Description: "Hand a task to Codex, a local coding agent that can read and edit files, run terminal commands and work in code repositories. " +
			"Use it for coding and for multi-step work on this Mac's files or repositories; a quick command you can run yourself with run_command. " +
			"Do not use it for general questions, chat, weather, news or anything you can answer directly.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"task": map[string]any{
					"type":        "string",
					"description": "A complete, self-contained instruction for Codex, in the user's language.",
				},
			},
			"required": []string{"task"},
		},
	}
}

func (delegateToCodex) Activity() Activity {
	return Activity{Kind: ActivityRunning, Label: "Handing off to Codex"}
}

func (t delegateToCodex) Run(_ context.Context, args json.RawMessage) (ToolResult, error) {
	if t.available != nil && !t.available() {
		return ToolResult{Content: "Codex is not set up, so nothing was handed off. Tell the user, in their language, " +
			"to open the Executors page in Crow (执行器 in the Chinese interface) and add the Codex connector, then ask again."}, nil
	}
	var in struct {
		Task string `json:"task"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return ToolResult{}, fmt.Errorf("invalid arguments: %w", err)
	}
	if strings.TrimSpace(in.Task) == "" {
		return ToolResult{}, fmt.Errorf("task is required")
	}
	return ToolResult{Handoff: &Handoff{Executor: "codex", Task: strings.TrimSpace(in.Task)}}, nil
}
