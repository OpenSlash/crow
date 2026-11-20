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
Start with a screenshot. Coordinates are pixels in the most recent full screenshot. Every action returns a fresh screenshot, the pointer position and the front window; check them before the next step.
In app windows, call elements first: it numbers the window's controls and draws the numbers on a screenshot. Prefer click with element and set_value with element over coordinates; they are far more reliable. Element numbers expire at the next elements call.
Use zoom to read small text or icons before clicking them; zoom images never change the coordinate space.
To switch apps or windows, prefer windows + focus or open_app over clicking the Dock. Prefer keyboard shortcuts over hunting for small targets.
Set screenshot to false only for steps whose result you do not need to see, such as typing into a field you just clicked.
Never type passwords, sign in, enter payment details, approve purchases or change security or privacy settings: stop and ask the user to do that step.
If an action reports that the user is using the computer, stop and say so.
When the task is done or cannot be done, reply without calling tools: one or two sentences in the user's language.`

// keepScreenshots is how many recent screenshots stay in the conversation.
const keepScreenshots = 2

type Executor struct {
	// busy admits one computer task at a time; two would interleave their actions.
	busy     chan struct{}
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
	return &Executor{busy: make(chan struct{}, 1), bridge: bridge, provider: provider, seeOnly: seeOnly, maxSteps: maxSteps}
}

// maxTypeLength bounds one type action so a cancelled task stops typing quickly.
const maxTypeLength = 2000

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
	select {
	case e.busy <- struct{}{}:
	default:
		_ = sink.ApplyExecutorEvent(ctx, req.TaskID, executor.Event{Type: "executor.waiting", Title: "Waiting", Message: "Another computer task is running.", Status: "running", Subtitle: "Waiting for another task"})
		select {
		case e.busy <- struct{}{}:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	defer func() { <-e.busy }()
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

	tool := ToolSpec(seeOnly)
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
	if call.Name != "computer" {
		return llm.Message{Role: "tool", Content: "Error: unknown tool " + call.Name}
	}
	text, images, err := e.act(ctx, call.Arguments, seeOnly, approve, event)
	switch {
	case errors.Is(err, errDeclined):
		return llm.Message{Role: "tool", Content: "The user declined this action. Do not retry it."}
	case err != nil:
		return llm.Message{Role: "tool", Content: "Error: " + err.Error()}
	}
	return llm.Message{Role: "tool", Content: text, Images: images}
}

var errDeclined = errors.New("the user declined this action")

// act validates and performs one action given as the tool's JSON arguments, asking
// for approval unless it only looks. It returns the text and images for the model.
func (e *Executor) act(ctx context.Context, argsJSON string, seeOnly bool, approve func(string, string) (bool, error), event func(executor.Event)) (string, []llm.Image, error) {
	var args map[string]any
	if err := json.Unmarshal([]byte(argsJSON), &args); err != nil {
		return "", nil, fmt.Errorf("invalid arguments: %v", err)
	}
	action, _ := args["action"].(string)
	label, ok := actionLabels[action]
	if !ok {
		return "", nil, fmt.Errorf("unknown action %q", action)
	}
	delete(args, "action")
	if text, _ := args["text"].(string); len([]rune(text)) > maxTypeLength {
		return "", nil, fmt.Errorf("text is longer than %d characters; type it in parts", maxTypeLength)
	}
	event(executor.Event{Type: "tool.started", Title: label, Message: describe(action, args), Status: "running", Subtitle: label})

	if !readOnly[action] {
		if seeOnly {
			return "", nil, errors.New("see-only mode is on: you may only look at the screen")
		}
		ok, err := approve(label, describe(action, args))
		if err != nil {
			return "", nil, err
		}
		if !ok {
			return "", nil, errDeclined
		}
	}
	if action == "wait" {
		seconds, _ := args["seconds"].(float64)
		select {
		case <-time.After(time.Duration(min(max(seconds, 0.5), 10) * float64(time.Second))):
		case <-ctx.Done():
			return "", nil, ctx.Err()
		}
		action, args = "screenshot", map[string]any{}
	}

	res, err := e.bridge.Do(ctx, action, args)
	if err != nil {
		return "", nil, err
	}
	if !res.GetOk() {
		return "", nil, errors.New(res.GetError())
	}
	text := "OK"
	if t := strings.TrimSpace(res.GetText()); t != "" {
		text = t
	}
	if len(res.GetImage()) == 0 {
		return text, nil, nil
	}
	if action == "zoom" {
		text += fmt.Sprintf(" Zoomed image %dx%d attached; coordinates still refer to the full screenshot.", res.GetWidth(), res.GetHeight())
	} else {
		text += fmt.Sprintf(" Screenshot %dx%d attached.", res.GetWidth(), res.GetHeight())
	}
	return text, []llm.Image{{MediaType: firstNonEmpty(res.GetImageMediaType(), "image/jpeg"), Data: res.GetImage()}}, nil
}

// Perform runs one action for an external agent (the MCP server) under the same
// rules as a Crow task: the enabled switch, see-only mode, approvals under the
// `computer` scope for taskID, and never while a Crow computer task is running.
func (e *Executor) Perform(ctx context.Context, taskID, argsJSON string, sink executor.Sink) (string, []llm.Image, error) {
	if e.enabled != nil && !e.enabled() {
		return "", nil, errors.New("computer use is turned off; the user can enable it in Crow Settings")
	}
	select {
	case e.busy <- struct{}{}:
		defer func() { <-e.busy }()
	default:
		return "", nil, errors.New("Crow is using the computer for another task; try again later")
	}
	approvals, _ := sink.(executor.ApprovalSink)
	if approvals == nil {
		return "", nil, errors.New("computer use needs approvals")
	}
	approve := func(action, preview string) (bool, error) {
		return approvals.RequestApproval(ctx, taskID, executor.ApprovalRequest{
			Scope: "computer", Tool: "computer", Action: action, Preview: preview, Description: "External agent: " + preview, RiskLevel: 3,
		})
	}
	event := func(ev executor.Event) { _ = sink.ApplyExecutorEvent(ctx, taskID, ev) }
	defer event(executor.Event{Type: "executor.idle", Title: "External agent idle", Status: "completed", Subtitle: "Idle"})
	return e.act(ctx, argsJSON, e.seeOnly != nil && e.seeOnly(), approve, event)
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

// readOnly actions only look; they need no approval and work in see-only mode.
var readOnly = map[string]bool{"screenshot": true, "zoom": true, "windows": true, "elements": true, "wait": true}

var actionLabels = map[string]string{
	"screenshot": "Looking at the screen",
	"zoom":       "Looking closer",
	"windows":    "Listing windows",
	"elements":   "Reading the window",
	"set_value":  "Filling in",
	"focus":      "Switching windows",
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
	case "focus":
		return strings.TrimSpace(fmt.Sprintf("Switch to %v %v", args["name"], firstNonEmpty(fmt.Sprint(args["title"]))))
	case "click":
		if element, ok := args["element"]; ok {
			return fmt.Sprintf("%v click on element %v", firstNonEmpty(fmt.Sprint(args["button"]), "left"), element)
		}
		return fmt.Sprintf("%v click at (%v, %v)", firstNonEmpty(fmt.Sprint(args["button"]), "left"), args["x"], args["y"])
	case "set_value":
		text, _ := args["text"].(string)
		if len([]rune(text)) > 80 {
			text = string([]rune(text)[:80]) + "…"
		}
		return fmt.Sprintf("Set element %v to: %s", args["element"], text)
	default:
		data, _ := json.Marshal(args)
		return action + " " + string(data)
	}
}

// ToolSpec is the generic computer tool; seeOnly offers only the looking actions.
func ToolSpec(seeOnly bool) llm.Tool {
	actions := []string{"screenshot", "elements", "zoom", "windows", "click", "set_value", "move", "drag", "type", "key", "scroll", "open_app", "focus", "wait"}
	if seeOnly {
		actions = []string{"screenshot", "elements", "zoom", "windows", "wait"}
	}
	number := func(desc string) map[string]any { return map[string]any{"type": "number", "description": desc} }
	return llm.Tool{
		Name: "computer",
		Description: "Control the Mac's main display. Actions: screenshot; elements (number the front window's controls, listed and drawn on a screenshot); " +
			"zoom (x, y, width, height: a region of the latest screenshot at full detail); " +
			"windows (list open windows with app, title and bounds); click (element, or x and y; optional button left|right|middle, count 1-3); " +
			"set_value (element, text: fill a text field directly); " +
			"move (x, y); drag (x, y to to_x, to_y); type (text); key (keys like \"cmd+c\", \"return\", \"cmd+shift+4\"); " +
			"scroll (x, y, direction up|down|left|right, amount in lines); open_app (name, e.g. \"Safari\"); " +
			"focus (name of the app, optional title of its window); wait (seconds). " +
			"Coordinates are pixels in the latest full screenshot. Actions return a new screenshot unless screenshot is false.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"action":     map[string]any{"type": "string", "enum": actions},
				"x":          number("Horizontal pixel in the latest screenshot."),
				"y":          number("Vertical pixel in the latest screenshot."),
				"to_x":       number("Drag end x."),
				"to_y":       number("Drag end y."),
				"button":     map[string]any{"type": "string", "enum": []string{"left", "right", "middle"}},
				"count":      map[string]any{"type": "integer", "minimum": 1, "maximum": 3},
				"text":       map[string]any{"type": "string", "maxLength": maxTypeLength},
				"keys":       map[string]any{"type": "string"},
				"direction":  map[string]any{"type": "string", "enum": []string{"up", "down", "left", "right"}},
				"amount":     map[string]any{"type": "integer", "minimum": 1, "maximum": 30},
				"name":       map[string]any{"type": "string"},
				"seconds":    number("Seconds to wait, up to 10."),
				"element":    map[string]any{"type": "integer", "minimum": 1, "description": "Element number from the latest elements call."},
				"width":      number("Zoom region width in screenshot pixels."),
				"height":     number("Zoom region height in screenshot pixels."),
				"title":      map[string]any{"type": "string", "description": "Window title (or part of it) for focus."},
				"screenshot": map[string]any{"type": "boolean", "description": "Attach a screenshot after the action (default true)."},
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
