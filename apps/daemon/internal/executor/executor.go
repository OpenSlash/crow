package executor

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

type Request struct {
	TaskID  string
	Kind    string
	Command string
}

type Event struct {
	Type            string
	Title           string
	Message         string
	Status          string
	Subtitle        string
	ApprovalTitle   string
	ApprovalAction  string
	ApprovalPreview string
	ApprovalRisk    int32
	Delay           time.Duration
}

type ApprovalRequest struct {
	Tool        string
	Action      string
	Preview     string
	Description string
	RiskLevel   int32
}

type Registry struct {
	executors []Executor
	fallback  Executor
}

func NewRegistry(executors ...Executor) Registry {
	return Registry{
		executors: executors,
		fallback:  MockExecutor{},
	}
}

func (r Registry) Select(kind string) Executor {
	for _, executor := range r.executors {
		if executor.EnabledFor(kind) {
			return executor
		}
	}
	return r.fallback
}

func (r Registry) Descriptors() []Descriptor {
	descriptors := make([]Descriptor, 0, len(r.executors)+1)
	for _, executor := range r.executors {
		if described, ok := executor.(DescribedExecutor); ok {
			descriptors = append(descriptors, described.Descriptor())
			continue
		}
		descriptors = append(descriptors, Descriptor{
			ID:      executor.ID(),
			Name:    executor.ID(),
			Adapter: "unknown",
			Enabled: true,
		})
	}
	if described, ok := r.fallback.(DescribedExecutor); ok {
		descriptor := described.Descriptor()
		descriptor.Fallback = true
		descriptors = append(descriptors, descriptor)
	}
	return descriptors
}

func (r Registry) CheckDescriptors(ctx context.Context) []Descriptor {
	descriptors := make([]Descriptor, 0, len(r.executors)+1)
	for _, executor := range r.executors {
		if checked, ok := executor.(HealthCheckedExecutor); ok {
			descriptors = append(descriptors, checked.CheckHealth(ctx))
			continue
		}
		if described, ok := executor.(DescribedExecutor); ok {
			descriptors = append(descriptors, described.Descriptor())
			continue
		}
		descriptors = append(descriptors, Descriptor{
			ID:           executor.ID(),
			Name:         executor.ID(),
			Adapter:      "unknown",
			Enabled:      true,
			Healthy:      true,
			HealthStatus: "ready",
		})
	}
	if described, ok := r.fallback.(DescribedExecutor); ok {
		descriptor := described.Descriptor()
		descriptor.Fallback = true
		descriptors = append(descriptors, descriptor)
	}
	return descriptors
}

type Descriptor struct {
	ID                string   `json:"id"`
	Name              string   `json:"name"`
	Description       string   `json:"description,omitempty"`
	Version           string   `json:"version,omitempty"`
	Publisher         string   `json:"publisher,omitempty"`
	Homepage          string   `json:"homepage,omitempty"`
	Adapter           string   `json:"adapter"`
	Kinds             []string `json:"kinds,omitempty"`
	Source            string   `json:"source,omitempty"`
	Command           string   `json:"command,omitempty"`
	Enabled           bool     `json:"enabled"`
	Configured        bool     `json:"configured"`
	Healthy           bool     `json:"healthy"`
	HealthStatus      string   `json:"healthStatus"`
	HealthMessage     string   `json:"healthMessage,omitempty"`
	SupportsStreaming bool     `json:"supportsStreaming"`
	SupportsApproval  bool     `json:"supportsApproval"`
	Fallback          bool     `json:"fallback,omitempty"`
}

type Sink interface {
	ApplyExecutorEvent(context.Context, string, Event) error
}

type ApprovalSink interface {
	RequestApproval(context.Context, string, ApprovalRequest) (bool, error)
}

type Executor interface {
	ID() string
	EnabledFor(kind string) bool
	Run(context.Context, Request, Sink) error
}

type DescribedExecutor interface {
	Descriptor() Descriptor
}

type HealthCheckedExecutor interface {
	CheckHealth(context.Context) Descriptor
}

type MockExecutor struct{}

func (MockExecutor) ID() string {
	return "mock"
}

func (MockExecutor) Descriptor() Descriptor {
	return Descriptor{
		ID:           "mock",
		Name:         "Mock",
		Description:  "Fallback executor used when no configured executor matches a task.",
		Adapter:      "mock",
		Enabled:      true,
		Configured:   true,
		Healthy:      true,
		HealthStatus: "ready",
		Fallback:     true,
	}
}

type CommandExecutor struct {
	id                string
	name              string
	description       string
	version           string
	publisher         string
	homepage          string
	command           string
	env               map[string]string
	kinds             map[string]bool
	kindList          []string
	source            string
	adapter           string
	supportsStreaming bool
	supportsApproval  bool
}

func NewCommandExecutor(id string, command string, kinds ...string) *CommandExecutor {
	executor := &CommandExecutor{
		id:                strings.TrimSpace(id),
		name:              strings.TrimSpace(id),
		description:       "Runs a command adapter through Crow's generic executor protocol.",
		command:           strings.TrimSpace(command),
		env:               map[string]string{},
		kinds:             map[string]bool{},
		source:            "env",
		adapter:           "command",
		supportsStreaming: true,
		supportsApproval:  false,
	}
	for _, kind := range kinds {
		kind = strings.TrimSpace(strings.ToLower(kind))
		if kind != "" {
			executor.kinds[kind] = true
			executor.kindList = append(executor.kindList, kind)
		}
	}
	return executor
}

func NewCommandExecutorFromConfig(config ExecutorAdapterConfig) *CommandExecutor {
	executor := NewCommandExecutor(config.ID, config.Command, config.Kinds...)
	if strings.TrimSpace(config.Name) != "" {
		executor.name = strings.TrimSpace(config.Name)
	}
	if strings.TrimSpace(config.Description) != "" {
		executor.description = strings.TrimSpace(config.Description)
	}
	executor.version = strings.TrimSpace(config.Version)
	executor.publisher = strings.TrimSpace(config.Publisher)
	executor.homepage = strings.TrimSpace(config.Homepage)
	executor.env = config.Env
	if executor.env == nil {
		executor.env = map[string]string{}
	}
	executor.source = strings.TrimSpace(config.Source)
	executor.adapter = firstNonEmpty(strings.TrimSpace(config.Adapter), "command")
	executor.supportsStreaming = config.SupportsStreaming
	executor.supportsApproval = config.SupportsApproval
	return executor
}

func (e *CommandExecutor) ID() string {
	return e.id
}

func (e *CommandExecutor) Descriptor() Descriptor {
	healthy := e.command != ""
	healthStatus := "ready"
	healthMessage := "Command adapter is configured."
	if !healthy {
		healthStatus = "missing_command"
		healthMessage = "Command is empty."
	}
	return Descriptor{
		ID:                e.id,
		Name:              firstNonEmpty(e.name, e.id),
		Description:       e.description,
		Version:           e.version,
		Publisher:         e.publisher,
		Homepage:          e.homepage,
		Adapter:           firstNonEmpty(e.adapter, "command"),
		Kinds:             append([]string{}, e.kindList...),
		Source:            e.source,
		Command:           e.command,
		Enabled:           e.command != "",
		Configured:        e.command != "",
		Healthy:           healthy,
		HealthStatus:      healthStatus,
		HealthMessage:     healthMessage,
		SupportsStreaming: e.supportsStreaming,
		SupportsApproval:  e.supportsApproval,
	}
}

func (e *CommandExecutor) EnabledFor(kind string) bool {
	return e.command != "" && e.kinds[strings.ToLower(strings.TrimSpace(kind))]
}

func (e *CommandExecutor) Run(ctx context.Context, request Request, sink Sink) error {
	if e.command == "" {
		return fmt.Errorf("%s command is not configured", e.id)
	}

	payload, err := json.Marshal(request)
	if err != nil {
		return err
	}

	if err := sink.ApplyExecutorEvent(ctx, request.TaskID, Event{
		Type:     "executor.started",
		Title:    e.id + " started",
		Message:  "Running command executor.",
		Status:   "running",
		Subtitle: "Starting " + e.id,
	}); err != nil {
		return err
	}

	cmd := exec.CommandContext(ctx, "sh", "-lc", e.command)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return killProcessGroup(cmd) }
	env := append(os.Environ(),
		"CROW_EXECUTOR_ID="+e.id,
		"CROW_TASK_ID="+request.TaskID,
		"CROW_TASK_KIND="+request.Kind,
		"CROW_TASK_COMMAND="+request.Command,
		"CROW_TASK_JSON="+string(payload),
	)
	for key, value := range e.env {
		if strings.TrimSpace(key) != "" {
			env = append(env, key+"="+value)
		}
	}
	cmd.Env = env

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("open stdout failed: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("open stderr failed: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start command failed: %w", err)
	}

	lines := make(chan string)
	done := make(chan struct{}, 2)
	scan := func(prefix string, scanner *bufio.Scanner) {
		defer func() { done <- struct{}{} }()
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" {
				continue
			}
			lines <- prefix + line
		}
		if err := scanner.Err(); err != nil {
			lines <- prefix + "scan failed: " + err.Error()
		}
	}

	go scan("", bufio.NewScanner(stdout))
	go scan("stderr: ", bufio.NewScanner(stderr))
	go func() {
		<-done
		<-done
		close(lines)
	}()

	for line := range lines {
		event := Event{}
		if err := json.Unmarshal([]byte(line), &event); err == nil && event.Type != "" {
			if err := sink.ApplyExecutorEvent(ctx, request.TaskID, event); err != nil {
				return err
			}
			continue
		}
		if err := sink.ApplyExecutorEvent(ctx, request.TaskID, Event{
			Type:    "executor.output",
			Title:   e.id + " output",
			Message: line,
			Status:  "running",
		}); err != nil {
			return err
		}
	}

	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("command failed: %w", err)
	}
	return sink.ApplyExecutorEvent(ctx, request.TaskID, Event{
		Type:     "task.completed",
		Title:    e.id + " completed",
		Message:  "Executor completed.",
		Status:   "completed",
		Subtitle: "Completed",
	})
}

func (MockExecutor) EnabledFor(kind string) bool {
	return true
}

func (MockExecutor) Run(ctx context.Context, request Request, sink Sink) error {
	for _, event := range mockEvents(request.Kind) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(event.Delay):
		}
		if err := sink.ApplyExecutorEvent(ctx, request.TaskID, event); err != nil {
			return err
		}
	}
	return nil
}

func mockEvents(kind string) []Event {
	switch kind {
	case "research":
		return []Event{
			{Delay: 500 * time.Millisecond, Type: "step.started", Title: "Searching sources", Message: "Generating search queries.", Status: "running", Subtitle: "Searching sources"},
			{Delay: 600 * time.Millisecond, Type: "step.completed", Title: "Search completed", Message: "Found candidate sources.", Status: "running", Subtitle: "Search completed"},
			{Delay: 600 * time.Millisecond, Type: "step.started", Title: "Summarizing findings", Message: "Synthesizing key findings.", Status: "running", Subtitle: "Summarizing"},
			{Delay: 600 * time.Millisecond, Type: "approval.required", Title: "Approval Required", Message: "Create Markdown research report.", Status: "waiting_approval", Subtitle: "Approval Required", ApprovalTitle: "Create research report", ApprovalAction: "Write Markdown report", ApprovalPreview: "Crow will create a local Markdown report from the research summary.", ApprovalRisk: 2},
		}
	case "email":
		return []Event{
			{Delay: 500 * time.Millisecond, Type: "email.started", Title: "Mail context opened", Message: "Crow is preparing the unread inbox view.", Status: "running", Subtitle: "Opening mail"},
			{Delay: 600 * time.Millisecond, Type: "email.scanning", Title: "Unread emails scanned", Message: "Grouped unread messages by urgency.", Status: "running", Subtitle: "Scanning unread"},
			{Delay: 600 * time.Millisecond, Type: "approval.required", Title: "Approval Required", Message: "Review the email summary before saving.", Status: "waiting_approval", Subtitle: "Approval Required", ApprovalTitle: "Save email summary", ApprovalAction: "Create summary note", ApprovalPreview: "Crow will save a local summary of unread emails.", ApprovalRisk: 2},
		}
	case "code", "agent":
		return []Event{
			{Delay: 500 * time.Millisecond, Type: "executor.selected", Title: "No executor configured", Message: "Install a code executor connector such as Codex to delegate this task.", Status: "running", Subtitle: "Routing task"},
			{Delay: 700 * time.Millisecond, Type: "executor.status", Title: "Connector required", Message: "Crow Core is ready, but this request needs an installed executor plugin.", Status: "running", Subtitle: "Connector required"},
			{Delay: 700 * time.Millisecond, Type: "task.completed", Title: "Connector setup needed", Message: "Open Executors and install a connector before running code or agent tasks.", Status: "completed", Subtitle: "Setup needed"},
		}
	default:
		return []Event{
			{Delay: 500 * time.Millisecond, Type: "step.started", Title: "Crow started", Message: "Crow is preparing the task.", Status: "running", Subtitle: "Working"},
			{Delay: 700 * time.Millisecond, Type: "task.completed", Title: "Task completed", Message: "Daemon mock executor completed this task.", Status: "completed", Subtitle: "Completed"},
		}
	}
}
