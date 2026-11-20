package computer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/crow/crow/apps/daemon/internal/executor"
	"github.com/crow/crow/apps/daemon/internal/llm"
)

// Kind is the task kind routed to computer use.
const Kind = "computer"

const systemPrompt = `You operate the user's Mac to complete a task, using the computer tool.
Start with a screenshot. Coordinates are pixels in the most recent screenshot. Every action returns a fresh screenshot; check it before the next step.
Prefer open_app and keyboard shortcuts over hunting for small targets.
Never type passwords, sign in, enter payment details, approve purchases or change security or privacy settings: stop and ask the user to do that step.
If an action reports that the user is using the computer, stop and say so.
When the task is done or cannot be done, reply without calling tools: one or two sentences in the user's language.`

// keepScreenshots is how many recent screenshots stay in the conversation.
const keepScreenshots = 2

type Executor struct {
	enabled  func() bool
	bridge   *Bridge
	provider func() (llm.Provider, error)
	seeOnly  func() bool
	maxSteps int
}

func NewExecutor(bridge *Bridge, provider func() (llm.Provider, error), seeOnly func() bool, maxSteps int) *Executor {
	if maxSteps <= 0 {
		maxSteps = 40
	}
	return &Executor{bridge: bridge, provider: provider, seeOnly: seeOnly, maxSteps: maxSteps}
}

// WithEnabled makes Run refuse while enabled reports false.
func (e *Executor) WithEnabled(enabled func() bool) *Executor {
	e.enabled = enabled
	return e
}

func (e *Executor) ID() string                  { return "computer" }
func (e *Executor) EnabledFor(kind string) bool { return kind == Kind }

func (e *Executor) Descriptor() executor.Descriptor {
	return executor.Descriptor{
		ID: "computer", Name: "Computer use", Adapter: "builtin",
		Description: "Sees the screen and uses the mouse and keyboard through the Crow app.",
		Enabled:     true, Configured: true, Healthy: true, HealthStatus: "ready",
		Kinds: []string{Kind},
	}
}

func (e *Executor) Run(ctx context.Context, req executor.Request, sink executor.Sink) error {
	if e.enabled != nil && !e.enabled() {
		return errors.New("computer use is turned off; enable it in Crow Settings")
	}
	provider, err := e.provider()
	if err != nil {
		return err
	}
	approvals, _ := sink.(executor.ApprovalSink)
	if approvals == nil {
		return errors.New("computer use needs approvals")
	}
	seeOnly := e.seeOnly != nil && e.seeOnly()
	approve := func(action, preview string) (bool, error) {
		return approvals.RequestApproval(ctx, req.TaskID, executor.ApprovalRequest{
			Scope: "computer", Tool: "computer", Action: action, Preview: preview, Description: preview, RiskLevel: 3,
		})
	}
	if ok, err := approve("Use the computer", req.Command); err != nil {
		return err
	} else if !ok {
		return errors.New("computer use was not approved")
	}
	// Whatever happens, leave no key or button held down.
	defer func() {
		releaseCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
		defer cancel()
		_, _ = e.bridge.Do(releaseCtx, "release", map[string]any{})
	}()

	event := func(ev executor.Event) { _ = sink.ApplyExecutorEvent(ctx, req.TaskID, ev) }
	event(executor.Event{Type: "executor.started", Title: "Computer use started", Message: req.Command, Status: "running", Subtitle: "Looking at the screen"})

	tool := toolSpec(seeOnly)
	messages := []llm.Message{{Role: "user", Content: req.Command}}
	for step := 0; step < e.maxSteps; step++ {
		if err := ctx.Err(); err != nil {
			return err
		}
		resp, err := provider.Stream(ctx, llm.Request{
			System: systemPrompt, Messages: messages, Tools: []llm.Tool{tool}, MaxTokens: 2048, Temperature: 0,
		}, func(string) error { return nil })
		if err != nil {
			return err
		}
		if len(resp.ToolCalls) == 0 {
			event(executor.Event{Type: "task.completed", Title: "Computer use finished", Message: strings.TrimSpace(resp.Text), Status: "completed", Subtitle: "Completed"})
			return nil
		}
		messages = append(messages, llm.Message{Role: "assistant", Content: resp.Text, ToolCalls: resp.ToolCalls})
		for _, call := range resp.ToolCalls {
			if err := ctx.Err(); err != nil {
				return err
			}
			result := e.runAction(ctx, call, seeOnly, approve, event)
			result.ToolCallID = call.ID
			messages = append(messages, result)
		}
		pruneScreenshots(messages, keepScreenshots)
	}
	event(executor.Event{Type: "task.completed", Title: "Computer use stopped", Message: "The task took too many steps.", Status: "completed", Subtitle: "Stopped"})
	return nil
}

// runAction performs one tool call and returns the tool message for the model.
func (e *Executor) runAction(ctx context.Context, call llm.ToolCall, seeOnly bool, approve func(string, string) (bool, error), event func(executor.Event)) llm.Message {
	fail := func(format string, args ...any) llm.Message {
		return llm.Message{Role: "tool", Content: "Error: " + fmt.Sprintf(format, args...)}
	}
	if call.Name != "computer" {
		return fail("unknown tool %s", call.Name)
	}
	var args map[string]any
	if err := json.Unmarshal([]byte(call.Arguments), &args); err != nil {
		return fail("invalid arguments: %v", err)
	}
	action, _ := args["action"].(string)
	label, ok := actionLabels[action]
	if !ok {
		return fail("unknown action %q", action)
	}
	delete(args, "action")
	event(executor.Event{Type: "tool.started", Title: label, Message: describe(action, args), Status: "running", Subtitle: label})

	if action != "screenshot" && action != "wait" {
		if seeOnly {
			return fail("see-only mode is on: you may only take screenshots")
		}
		ok, err := approve(label, describe(action, args))
		if err != nil {
			return fail("%v", err)
		}
		if !ok {
			return llm.Message{Role: "tool", Content: "The user declined this action. Do not retry it."}
		}
	}
	if action == "wait" {
		seconds, _ := args["seconds"].(float64)
		select {
		case <-time.After(time.Duration(min(max(seconds, 0.5), 10) * float64(time.Second))):
		case <-ctx.Done():
			return fail("cancelled")
		}
		action, args = "screenshot", map[string]any{}
	}

	res, err := e.bridge.Do(ctx, action, args)
	if err != nil {
		return fail("%v", err)
	}
	if !res.GetOk() {
		return fail("%s", res.GetError())
	}
	msg := llm.Message{Role: "tool", Content: "OK"}
	if text := strings.TrimSpace(res.GetText()); text != "" {
		msg.Content = text
	}
	if len(res.GetImage()) > 0 {
		msg.Content += fmt.Sprintf(" Screenshot %dx%d attached.", res.GetWidth(), res.GetHeight())
		msg.Images = []llm.Image{{MediaType: firstNonEmpty(res.GetImageMediaType(), "image/jpeg"), Data: res.GetImage()}}
	}
	return msg
}

// pruneScreenshots drops all but the newest `keep` images to bound request size.
func pruneScreenshots(messages []llm.Message, keep int) {
	for i := len(messages) - 1; i >= 0; i-- {
		if len(messages[i].Images) == 0 {
			continue
		}
		if keep > 0 {
			keep--
			continue
		}
		messages[i].Images = nil
		messages[i].Content += " (older screenshot removed)"
	}
}

var actionLabels = map[string]string{
	"screenshot": "Looking at the screen",
	"click":      "Clicking",
	"move":       "Moving the pointer",
	"drag":       "Dragging",
	"type":       "Typing",
	"key":        "Pressing keys",
	"scroll":     "Scrolling",
	"open_app":   "Opening an app",
	"wait":       "Waiting",
}

func describe(action string, args map[string]any) string {
	switch action {
	case "type":
		text, _ := args["text"].(string)
		if len([]rune(text)) > 80 {
			text = string([]rune(text)[:80]) + "…"
		}
		return "Type: " + text
	case "key":
		return fmt.Sprintf("Press %v", args["keys"])
	case "open_app":
		return fmt.Sprintf("Open %v", args["name"])
	case "click":
		return fmt.Sprintf("%v click at (%v, %v)", firstNonEmpty(fmt.Sprint(args["button"]), "left"), args["x"], args["y"])
	default:
		data, _ := json.Marshal(args)
		return action + " " + string(data)
	}
}

func toolSpec(seeOnly bool) llm.Tool {
	actions := []string{"screenshot", "click", "move", "drag", "type", "key", "scroll", "open_app", "wait"}
	if seeOnly {
		actions = []string{"screenshot", "wait"}
	}
	number := func(desc string) map[string]any { return map[string]any{"type": "number", "description": desc} }
	return llm.Tool{
		Name: "computer",
		Description: "Control the Mac's main display. Actions: screenshot; click (x, y, optional button left|right|middle, count 1-3); " +
			"move (x, y); drag (x, y to to_x, to_y); type (text); key (keys like \"cmd+c\", \"return\", \"cmd+shift+4\"); " +
			"scroll (x, y, direction up|down|left|right, amount in lines); open_app (name, e.g. \"Safari\"); wait (seconds). " +
			"Coordinates are pixels in the latest screenshot. Every action returns a new screenshot.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"action":    map[string]any{"type": "string", "enum": actions},
				"x":         number("Horizontal pixel in the latest screenshot."),
				"y":         number("Vertical pixel in the latest screenshot."),
				"to_x":      number("Drag end x."),
				"to_y":      number("Drag end y."),
				"button":    map[string]any{"type": "string", "enum": []string{"left", "right", "middle"}},
				"count":     map[string]any{"type": "integer", "minimum": 1, "maximum": 3},
				"text":      map[string]any{"type": "string"},
				"keys":      map[string]any{"type": "string"},
				"direction": map[string]any{"type": "string", "enum": []string{"up", "down", "left", "right"}},
				"amount":    map[string]any{"type": "integer", "minimum": 1, "maximum": 30},
				"name":      map[string]any{"type": "string"},
				"seconds":   number("Seconds to wait, up to 10."),
			},
			"required": []string{"action"},
		},
	}
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v = strings.TrimSpace(v); v != "" && v != "<nil>" {
			return v
		}
	}
	return ""
}
