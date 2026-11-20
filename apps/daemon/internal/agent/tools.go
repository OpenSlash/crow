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

type delegateToCodex struct{}

// DelegateToCodex hands coding, file and terminal work to the Codex executor.
func DelegateToCodex() Tool { return delegateToCodex{} }

func (delegateToCodex) Spec() llm.Tool {
	return llm.Tool{
		Name: "delegate_to_codex",
		Description: "Hand a task to Codex, a local coding agent that can read and edit files, run terminal commands and work in code repositories. " +
			"Use it for any request that needs local files, code, the terminal or long-running execution. " +
			"Do not use it for questions you can answer directly.",
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

func (delegateToCodex) Run(_ context.Context, args json.RawMessage) (ToolResult, error) {
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
