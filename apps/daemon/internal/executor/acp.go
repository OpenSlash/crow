package executor

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

// acpCancelGrace is how long a cancelled ACP turn may take to stop on its own
// after session/cancel before the process is killed.
var acpCancelGrace = 3 * time.Second

type ACPExecutor struct {
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
	supportsStreaming bool
	supportsApproval  bool
}

type acpRPCEnvelope struct {
	JSONRPC string          `json:"jsonrpc,omitempty"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *acpRPCError    `json:"error,omitempty"`
}

type acpRPCError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

type acpRPCResponse struct {
	Result json.RawMessage
	Error  *acpRPCError
}

type acpClient struct {
	stdin     io.WriteCloser
	writeMu   sync.Mutex
	mu        sync.Mutex
	nextID    int64
	pending   map[string]chan acpRPCResponse
	done      chan struct{}
	closeOnce sync.Once
	handler   func(context.Context, acpRPCEnvelope)
	ctx       context.Context
}

func NewACPExecutorFromConfig(config ExecutorAdapterConfig) *ACPExecutor {
	executor := &ACPExecutor{
		id:                normalizeAdapterID(config.ID),
		name:              strings.TrimSpace(config.Name),
		description:       strings.TrimSpace(config.Description),
		version:           strings.TrimSpace(config.Version),
		publisher:         strings.TrimSpace(config.Publisher),
		homepage:          strings.TrimSpace(config.Homepage),
		command:           strings.TrimSpace(config.Command),
		env:               config.Env,
		kinds:             map[string]bool{},
		source:            strings.TrimSpace(config.Source),
		supportsStreaming: true,
		supportsApproval:  true,
	}
	if executor.id == "" {
		executor.id = "acp"
	}
	if executor.name == "" {
		executor.name = executor.id
	}
	if executor.description == "" {
		executor.description = "Runs an Agent Client Protocol executor."
	}
	if executor.env == nil {
		executor.env = map[string]string{}
	}
	if !config.SupportsStreaming {
		executor.supportsStreaming = false
	}
	if !config.SupportsApproval {
		executor.supportsApproval = false
	}
	for _, kind := range normalizeAdapterKinds(config.Kinds) {
		executor.kinds[kind] = true
		executor.kindList = append(executor.kindList, kind)
	}
	if len(executor.kinds) == 0 {
		executor.kinds["code"] = true
		executor.kinds["agent"] = true
		executor.kindList = []string{"code", "agent"}
	}
	return executor
}

func (e *ACPExecutor) ID() string {
	return e.id
}

func (e *ACPExecutor) EnabledFor(kind string) bool {
	return e.command != "" && e.kinds[strings.ToLower(strings.TrimSpace(kind))]
}

func (e *ACPExecutor) Descriptor() Descriptor {
	healthy := e.command != ""
	status := "ready"
	message := "ACP executor is configured."
	if !healthy {
		status = "missing_command"
		message = "ACP command is empty."
	}
	return Descriptor{
		ID:                e.id,
		Name:              firstNonEmpty(e.name, e.id),
		Description:       e.description,
		Version:           e.version,
		Publisher:         e.publisher,
		Homepage:          e.homepage,
		Adapter:           "acp",
		Kinds:             append([]string{}, e.kindList...),
		Source:            e.source,
		Command:           e.command,
		Enabled:           e.command != "",
		Configured:        e.command != "",
		Healthy:           healthy,
		HealthStatus:      status,
		HealthMessage:     message,
		SupportsStreaming: e.supportsStreaming,
		SupportsApproval:  e.supportsApproval,
	}
}

func (e *ACPExecutor) CheckHealth(ctx context.Context) Descriptor {
	descriptor := e.Descriptor()
	if !descriptor.Healthy {
		return descriptor
	}

	checkCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	cmd, client, err := e.startACP(checkCtx, nil)
	if err != nil {
		descriptor.Healthy = false
		descriptor.HealthStatus = "start_failed"
		descriptor.HealthMessage = err.Error()
		return descriptor
	}
	defer stopACPProcess(cmd, client)

	var result map[string]any
	if err := client.Call(checkCtx, "initialize", acpInitializeParams(), &result); err != nil {
		descriptor.Healthy = false
		descriptor.HealthStatus = "initialize_failed"
		descriptor.HealthMessage = "ACP initialize failed: " + err.Error()
		return descriptor
	}
	var session struct {
		SessionID string `json:"sessionId"`
	}
	if err := client.Call(checkCtx, "session/new", map[string]any{
		"cwd":        resolveACPCwd(),
		"mcpServers": []any{},
	}, &session); err != nil {
		descriptor.Healthy = false
		descriptor.HealthStatus = "session_failed"
		descriptor.HealthMessage = "ACP session/new failed: " + err.Error()
		return descriptor
	}
	if strings.TrimSpace(session.SessionID) == "" {
		descriptor.Healthy = false
		descriptor.HealthStatus = "session_failed"
		descriptor.HealthMessage = "ACP session/new returned empty sessionId."
		return descriptor
	}
	descriptor.HealthStatus = "ready"
	descriptor.HealthMessage = "ACP agent initialized successfully."
	return descriptor
}

func (e *ACPExecutor) Run(ctx context.Context, request Request, sink Sink) error {
	if e.command == "" {
		return fmt.Errorf("%s ACP command is not configured", e.id)
	}
	if err := sink.ApplyExecutorEvent(ctx, request.TaskID, Event{
		Type:     "executor.started",
		Title:    firstNonEmpty(e.name, e.id) + " started",
		Message:  "Starting ACP executor.",
		Status:   "running",
		Subtitle: "Starting executor",
	}); err != nil {
		return err
	}

	var assistantBuffer acpTranscript
	handler := func(handlerCtx context.Context, envelope acpRPCEnvelope) {
		e.handleACPEnvelope(handlerCtx, request.TaskID, sink, envelope, &assistantBuffer)
	}
	// The process outlives ctx by acpCancelGrace so session/cancel can stop it cleanly.
	procCtx, stopProc := graceContext(ctx, acpCancelGrace)
	defer stopProc()
	cmd, client, err := e.startACP(procCtx, handler)
	if err != nil {
		return err
	}
	defer stopACPProcess(cmd, client)

	if err := client.Call(ctx, "initialize", acpInitializeParams(), nil); err != nil {
		return fmt.Errorf("ACP initialize failed: %w", err)
	}
	cwd := resolveACPCwd()
	var session struct {
		SessionID string `json:"sessionId"`
	}
	if err := client.Call(ctx, "session/new", map[string]any{
		"cwd":        cwd,
		"mcpServers": []any{},
	}, &session); err != nil {
		return fmt.Errorf("ACP session/new failed: %w", err)
	}
	if strings.TrimSpace(session.SessionID) == "" {
		return fmt.Errorf("ACP session/new returned empty sessionId")
	}
	if err := sink.ApplyExecutorEvent(ctx, request.TaskID, Event{
		Type:     "executor.session.started",
		Title:    "ACP session ready",
		Message:  session.SessionID,
		Status:   "running",
		Subtitle: "Session ready",
	}); err != nil {
		return err
	}

	var promptResult map[string]any
	promptDone := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = client.write(map[string]any{"jsonrpc": "2.0", "method": "session/cancel", "params": map[string]any{"sessionId": session.SessionID}})
		case <-promptDone:
		}
	}()
	err = client.Call(procCtx, "session/prompt", map[string]any{
		"sessionId": session.SessionID,
		"prompt": []map[string]any{{
			"type": "text",
			"text": acpCrowInput(request),
		}},
	}, &promptResult)
	close(promptDone)
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if err != nil {
		return fmt.Errorf("ACP session/prompt failed: %w", err)
	}
	message := assistantBuffer.answer()
	if message == "" {
		message = firstNonEmpty(getString(promptResult, "stopReason"), "ACP turn completed.")
	}
	return sink.ApplyExecutorEvent(ctx, request.TaskID, Event{
		Type:     "task.completed",
		Title:    firstNonEmpty(e.name, e.id) + " conclusion",
		Message:  message,
		Status:   "completed",
		Subtitle: "Completed",
	})
}

func (e *ACPExecutor) startACP(ctx context.Context, handler func(context.Context, acpRPCEnvelope)) (*exec.Cmd, *acpClient, error) {
	cmd := exec.CommandContext(ctx, "sh", "-lc", e.command)
	// Own process group, so cancelling also stops the agent's child processes.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return killProcessGroup(cmd) }
	cmd.Dir = resolveACPCwd()
	env := append(os.Environ(), "CROW_EXECUTOR_ID="+e.id)
	for key, value := range e.env {
		if strings.TrimSpace(key) != "" {
			env = append(env, key+"="+value)
		}
	}
	cmd.Env = env
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, nil, fmt.Errorf("open ACP stdin failed: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, fmt.Errorf("open ACP stdout failed: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, nil, fmt.Errorf("open ACP stderr failed: %w", err)
	}
	client := &acpClient{
		stdin:   stdin,
		pending: map[string]chan acpRPCResponse{},
		done:    make(chan struct{}),
		handler: handler,
		ctx:     ctx,
	}
	if err := cmd.Start(); err != nil {
		return nil, nil, fmt.Errorf("start ACP executor failed: %w", err)
	}
	go client.readLoop(stdout)
	go discardOrLogACPStderr(ctx, stderr)
	return cmd, client, nil
}

func (e *ACPExecutor) handleACPEnvelope(ctx context.Context, taskID string, sink Sink, envelope acpRPCEnvelope, assistantBuffer *acpTranscript) {
	switch strings.TrimSpace(envelope.Method) {
	case "session/update":
		params := parseJSONMap(envelope.Params)
		update := asMap(params["update"])
		e.handleACPUpdate(ctx, taskID, sink, update, assistantBuffer)
	case "session/request_permission":
		e.handleACPPermission(ctx, taskID, sink, envelope)
	default:
		if len(envelope.ID) > 0 {
			if client := acpClientFromContext(ctx); client != nil {
				_ = client.RespondError(envelope.ID, -32601, "ACP client method is not supported: "+envelope.Method)
			}
			_ = sink.ApplyExecutorEvent(ctx, taskID, Event{
				Type:     "executor.request.unsupported",
				Title:    "Unsupported ACP request",
				Message:  envelope.Method,
				Status:   "running",
				Subtitle: "ACP request",
			})
		}
	}
}

// acpTranscript accumulates the agent's reply. Agents stream it in tiny chunks
// (often a token at a time), so progress is published at most every
// acpOutputInterval; the complete reply goes out once, with task.completed.
type acpTranscript struct {
	text      strings.Builder
	published time.Time
	// answerStart is where the text after the latest tool call begins: agents
	// narrate before using tools, and the answer follows the last one.
	answerStart int
	thought     strings.Builder
	thoughtAt   time.Time
}

// answer is the reply after the last tool call, or the whole reply without tools.
func (t *acpTranscript) answer() string {
	full := t.text.String()
	if answer := strings.TrimSpace(full[min(t.answerStart, len(full)):]); answer != "" {
		return answer
	}
	return strings.TrimSpace(full)
}

const acpOutputInterval = 800 * time.Millisecond

func (e *ACPExecutor) handleACPUpdate(ctx context.Context, taskID string, sink Sink, update map[string]any, assistantBuffer *acpTranscript) {
	switch getString(update, "sessionUpdate") {
	case "agent_message_chunk":
		text := acpContentText(update["content"])
		if text == "" {
			return
		}
		assistantBuffer.text.WriteString(text)
		// No per-chunk voice segments: fragments like "202" or "|" were shown and
		// spoken on the island. The conclusion is spoken when the task completes.
		if time.Since(assistantBuffer.published) < acpOutputInterval {
			return
		}
		assistantBuffer.published = time.Now()
		_ = sink.ApplyExecutorEvent(ctx, taskID, Event{Type: "executor.output", Title: firstNonEmpty(e.name, e.id) + " output", Message: assistantBuffer.text.String(), Status: "running", Subtitle: "Responding"})
	case "agent_thought_chunk":
		text := acpContentText(update["content"])
		if text == "" {
			return
		}
		assistantBuffer.thought.WriteString(text)
		if time.Since(assistantBuffer.thoughtAt) < acpOutputInterval {
			return
		}
		assistantBuffer.thoughtAt = time.Now()
		_ = sink.ApplyExecutorEvent(ctx, taskID, Event{Type: "executor.thought", Title: "Agent thinking", Message: lastRunes(assistantBuffer.thought.String(), 400), Status: "running", Subtitle: "Thinking"})
	case "plan":
		if text := acpPlanText(update); text != "" {
			_ = sink.ApplyExecutorEvent(ctx, taskID, Event{Type: "executor.plan", Title: "Plan updated", Message: text, Status: "running", Subtitle: "Planning"})
		}
	case "tool_call":
		assistantBuffer.answerStart = assistantBuffer.text.Len()
		title := firstNonEmpty(getString(update, "title"), getString(update, "name"), "Tool call")
		_ = sink.ApplyExecutorEvent(ctx, taskID, Event{Type: "tool.started", Title: title, Message: acpToolMessage(update), Status: "running", Subtitle: acpActivityLabel(getString(update, "kind"))})
	case "tool_call_update":
		status := getString(update, "status")
		title := firstNonEmpty(getString(update, "title"), getString(update, "name"), "Tool update")
		eventType := "tool.completed"
		if status == "failed" {
			eventType = "tool.failed"
		} else if status == "in_progress" || status == "pending" {
			eventType = "tool.started"
		}
		subtitle := "Tool " + firstNonEmpty(status, "updated")
		if eventType == "tool.started" {
			subtitle = acpActivityLabel(getString(update, "kind"))
		}
		_ = sink.ApplyExecutorEvent(ctx, taskID, Event{Type: eventType, Title: title, Message: acpToolMessage(update), Status: "running", Subtitle: subtitle})
	case "usage_update":
		_ = sink.ApplyExecutorEvent(ctx, taskID, Event{Type: "executor.usage", Title: "Usage updated", Message: acpUsageText(update), Status: "running", Subtitle: "Usage"})
	case "current_mode_update", "config_option_update", "available_commands_update", "session_info_update":
		_ = sink.ApplyExecutorEvent(ctx, taskID, Event{Type: "executor.status", Title: "ACP update", Message: getString(update, "sessionUpdate"), Status: "running", Subtitle: "ACP"})
	}
}

func (e *ACPExecutor) handleACPPermission(ctx context.Context, taskID string, sink Sink, envelope acpRPCEnvelope) {
	client := acpClientFromContext(ctx)
	if client == nil {
		return
	}
	params := parseJSONMap(envelope.Params)
	toolCall := asMap(params["toolCall"])
	options := asSlice(params["options"])
	title := firstNonEmpty(getString(toolCall, "title"), getString(toolCall, "name"), "Agent action")
	preview := acpToolMessage(toolCall)
	approved := false
	var err error
	if approvalSink, ok := sink.(ApprovalSink); ok {
		approved, err = approvalSink.RequestApproval(ctx, taskID, ApprovalRequest{
			Scope:       acpApprovalScope(getString(toolCall, "kind")),
			Tool:        firstNonEmpty(getString(toolCall, "name"), "acp"),
			Action:      title,
			Preview:     preview,
			Description: preview,
			RiskLevel:   acpRiskLevel(getString(toolCall, "kind")),
		})
	}
	if err != nil {
		approved = false
	}
	optionID := chooseACPOption(options, approved)
	if optionID == "" {
		_ = client.Respond(envelope.ID, map[string]any{"outcome": map[string]any{"outcome": "cancelled"}})
		return
	}
	_ = client.Respond(envelope.ID, map[string]any{"outcome": map[string]any{"outcome": "selected", "optionId": optionID}})
}

type acpContextKey struct{}

func acpClientFromContext(ctx context.Context) *acpClient {
	client, _ := ctx.Value(acpContextKey{}).(*acpClient)
	return client
}

func acpInitializeParams() map[string]any {
	return map[string]any{
		"protocolVersion": 1,
		"clientCapabilities": map[string]any{
			"fs": map[string]any{
				"readTextFile":  false,
				"writeTextFile": false,
			},
			"terminal": false,
			"auth": map[string]any{
				"terminal": false,
			},
		},
		"clientInfo": map[string]any{
			"name":    "crow",
			"title":   "Crow",
			"version": "0.1.0",
		},
	}
}

func acpCrowInput(request Request) string {
	command := strings.TrimSpace(request.Command)
	if command == "" {
		command = "Help me with this task."
	}
	return strings.TrimSpace(fmt.Sprintf(`You are running inside Crow, a Jarvis-like local assistant.

User request:
%s

Crow response requirements:
- Treat this as an agent conversation or task, not just a background job.
- Stream useful progress through ACP updates when possible.
- Final output should be concise and directly useful to the user.
- If you need risky file, command, or network actions, request permission through ACP.
`, command))
}

func resolveACPCwd() string {
	if cleaned := strings.TrimSpace(os.Getenv("CROW_EXECUTOR_CWD")); cleaned != "" {
		return cleaned
	}
	if cwd, err := os.Getwd(); err == nil {
		return cwd
	}
	return "."
}

func stopACPProcess(cmd *exec.Cmd, client *acpClient) {
	if client != nil {
		client.Close()
	}
	if cmd != nil && cmd.Process != nil {
		_ = killProcessGroup(cmd)
		_ = cmd.Wait()
	}
}

func killProcessGroup(cmd *exec.Cmd) error {
	if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil {
		return cmd.Process.Kill()
	}
	return nil
}

// graceContext is cancelled `grace` after parent is, or when stop is called.
func graceContext(parent context.Context, grace time.Duration) (context.Context, context.CancelFunc) {
	ctx, cancel := context.WithCancel(context.WithoutCancel(parent))
	stop := context.AfterFunc(parent, func() {
		timer := time.AfterFunc(grace, cancel)
		context.AfterFunc(ctx, func() { timer.Stop() })
	})
	return ctx, func() { stop(); cancel() }
}

func discardOrLogACPStderr(ctx context.Context, reader io.Reader) {
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return
		default:
		}
	}
}

func (c *acpClient) Call(ctx context.Context, method string, params any, out any) error {
	id := c.nextRequestID()
	rawID := []byte(fmt.Sprintf("%d", id))
	ch := make(chan acpRPCResponse, 1)
	c.mu.Lock()
	c.pending[string(rawID)] = ch
	c.mu.Unlock()
	defer c.removePending(string(rawID))

	if err := c.write(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params}); err != nil {
		return err
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-c.done:
		return fmt.Errorf("ACP executor disconnected")
	case response := <-ch:
		if response.Error != nil {
			return fmt.Errorf("%s", firstNonEmpty(response.Error.Message, fmt.Sprintf("ACP error %d", response.Error.Code)))
		}
		if out != nil && len(response.Result) > 0 {
			if err := json.Unmarshal(response.Result, out); err != nil {
				return err
			}
		}
		return nil
	}
}

func (c *acpClient) Respond(id json.RawMessage, result any) error {
	if len(id) == 0 {
		return fmt.Errorf("ACP request id is empty")
	}
	return c.write(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(id), "result": result})
}

func (c *acpClient) RespondError(id json.RawMessage, code int, message string) error {
	if len(id) == 0 {
		return fmt.Errorf("ACP request id is empty")
	}
	return c.write(map[string]any{
		"jsonrpc": "2.0",
		"id":      json.RawMessage(id),
		"error": map[string]any{
			"code":    code,
			"message": message,
		},
	})
}

func (c *acpClient) nextRequestID() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.nextID++
	return c.nextID
}

func (c *acpClient) write(payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_, err = c.stdin.Write(data)
	return err
}

func (c *acpClient) readLoop(reader io.Reader) {
	defer close(c.done)
	scanner := bufio.NewScanner(reader)
	buffer := make([]byte, 0, 1024*1024)
	scanner.Buffer(buffer, 16*1024*1024)
	for scanner.Scan() {
		data := bytes.TrimSpace(scanner.Bytes())
		if len(data) == 0 {
			continue
		}
		var envelope acpRPCEnvelope
		if err := json.Unmarshal(data, &envelope); err != nil {
			continue
		}
		if len(envelope.ID) > 0 && strings.TrimSpace(envelope.Method) == "" {
			if c.resolveResponse(envelope) {
				continue
			}
		}
		if strings.TrimSpace(envelope.Method) != "" && c.handler != nil {
			ctx := context.WithValue(c.ctx, acpContextKey{}, c)
			c.handler(ctx, envelope)
		}
	}
}

func (c *acpClient) resolveResponse(envelope acpRPCEnvelope) bool {
	id := string(bytes.TrimSpace(envelope.ID))
	c.mu.Lock()
	ch := c.pending[id]
	c.mu.Unlock()
	if ch == nil {
		return false
	}
	ch <- acpRPCResponse{Result: envelope.Result, Error: envelope.Error}
	return true
}

func (c *acpClient) removePending(id string) {
	c.mu.Lock()
	delete(c.pending, id)
	c.mu.Unlock()
}

func (c *acpClient) Close() {
	c.closeOnce.Do(func() {
		_ = c.stdin.Close()
	})
}

func parseJSONMap(raw json.RawMessage) map[string]any {
	result := map[string]any{}
	_ = json.Unmarshal(raw, &result)
	return result
}

func getString(values map[string]any, key string) string {
	value, ok := values[key]
	if !ok || value == nil {
		return ""
	}
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case fmt.Stringer:
		return strings.TrimSpace(typed.String())
	default:
		return strings.TrimSpace(fmt.Sprint(typed))
	}
}

func asMap(value any) map[string]any {
	if result, ok := value.(map[string]any); ok {
		return result
	}
	return map[string]any{}
}

func asSlice(value any) []any {
	if result, ok := value.([]any); ok {
		return result
	}
	return nil
}

// acpContentText returns a content block's text untrimmed: streamed chunks carry
// the spaces and newlines between words and lines.
func acpContentText(value any) string {
	content := asMap(value)
	if text, ok := content["text"].(string); ok {
		return text
	}
	if content != nil {
		return ""
	}
	return strings.TrimSpace(fmt.Sprint(value))
}

func acpPlanText(update map[string]any) string {
	entries := asSlice(update["entries"])
	lines := []string{}
	for _, entryValue := range entries {
		entry := asMap(entryValue)
		content := firstNonEmpty(getString(entry, "content"), getString(entry, "title"))
		status := getString(entry, "status")
		if content == "" {
			continue
		}
		if status != "" {
			content += " [" + status + "]"
		}
		lines = append(lines, content)
	}
	return strings.Join(lines, "\n")
}

// acpActivityLabel maps an ACP tool kind to the activity shown on the island.
// The labels match the activity vocabulary in internal/agent.
func acpActivityLabel(kind string) string {
	switch kind {
	case "read":
		return "Reading files"
	case "edit", "delete", "move":
		return "Editing files"
	case "search", "fetch":
		return "Searching"
	case "execute":
		return "Running command"
	case "think":
		return "Thinking"
	default:
		return "Using tool"
	}
}

func acpToolMessage(tool map[string]any) string {
	parts := []string{}
	for _, key := range []string{"kind", "status", "name", "title"} {
		if value := getString(tool, key); value != "" {
			parts = append(parts, key+": "+value)
		}
	}
	if raw := tool["rawInput"]; raw != nil {
		if data, err := json.Marshal(raw); err == nil {
			parts = append(parts, "input: "+string(data))
		}
	}
	if raw := tool["rawOutput"]; raw != nil {
		if data, err := json.Marshal(raw); err == nil {
			parts = append(parts, "output: "+string(data))
		}
	}
	return strings.Join(parts, "\n")
}

func acpUsageText(update map[string]any) string {
	used := fmt.Sprint(update["used"])
	size := fmt.Sprint(update["size"])
	if used == "<nil>" || size == "<nil>" {
		return "Usage updated."
	}
	return "Context " + used + " / " + size
}

func acpApprovalScope(kind string) string {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "execute":
		return "terminal"
	case "edit", "delete", "move":
		return "file_write"
	default:
		return "codex"
	}
}

func acpRiskLevel(kind string) int32 {
	switch strings.ToLower(strings.TrimSpace(kind)) {
	case "edit", "delete", "move":
		return 3
	case "execute":
		return 4
	case "fetch":
		return 2
	default:
		return 1
	}
}

func chooseACPOption(options []any, approved bool) string {
	preferred := []string{"allow_once", "allow_always"}
	if !approved {
		preferred = []string{"reject_once", "reject_always"}
	}
	for _, kind := range preferred {
		for _, optionValue := range options {
			option := asMap(optionValue)
			if getString(option, "kind") == kind {
				return getString(option, "optionId")
			}
		}
	}
	for _, optionValue := range options {
		option := asMap(optionValue)
		if id := getString(option, "optionId"); id != "" {
			return id
		}
	}
	return ""
}

// lastRunes keeps the end of s, at most n runes.
func lastRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return "…" + string(r[len(r)-n:])
}
