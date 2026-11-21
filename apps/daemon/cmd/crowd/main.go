package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"connectrpc.com/connect"
	crowv1 "github.com/crow/crow/apps/daemon/gen/crow/v1"
	"github.com/crow/crow/apps/daemon/gen/crow/v1/crowv1connect"
	"github.com/crow/crow/apps/daemon/internal/agent"
	"github.com/crow/crow/apps/daemon/internal/approval"
	"github.com/crow/crow/apps/daemon/internal/computer"
	"github.com/crow/crow/apps/daemon/internal/config"
	"github.com/crow/crow/apps/daemon/internal/dictation"
	"github.com/crow/crow/apps/daemon/internal/executor"
	"github.com/crow/crow/apps/daemon/internal/llm"
	"github.com/crow/crow/apps/daemon/internal/memory"
	"github.com/crow/crow/apps/daemon/internal/store"
	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
	"google.golang.org/protobuf/proto"
)

type sessionFile struct {
	PID       int    `json:"pid"`
	BaseURL   string `json:"baseURL"`
	Token     string `json:"token"`
	StartedAt string `json:"startedAt"`
}

type server struct {
	mu           sync.Mutex
	store        *store.Store
	startedAt    time.Time
	state        *crowv1.RuntimeState
	settings     *crowv1.Settings
	executors    executor.Registry
	warnings     []string
	approvals    map[string]chan bool
	taskWatchers map[string]map[chan *crowv1.TaskEvent]struct{}
	// cancels holds the cancel func of each running task.
	cancels  map[string]context.CancelFunc
	gate     *approval.Gate
	bridge   *computer.Bridge
	computer *computer.Executor
	// conversation is the voice conversation's short-term context; task results
	// join it so follow-ups can refer to them.
	conversation *agent.Conversation
}

func newServer(store *store.Store) *server {
	executors, warnings := executor.BuildConfiguredExecutors()
	for _, warning := range warnings {
		log.Printf("executor adapter warning: %s", warning)
	}
	bridge := computer.NewBridge()
	computerExecutor := computer.NewExecutor(bridge, llmProvider,
		func() bool { return boolEnvDefault("CROW_COMPUTER_SEE_ONLY", false) },
		intEnv("CROW_AGENT_MAX_STEPS", agent.DefaultMaxSteps)).WithEnabled(computerUseEnabled)
	executors = append([]executor.Executor{computerExecutor}, executors...)
	return &server{
		conversation: agent.NewConversation(agent.DefaultConversationIdle),
		bridge:       bridge,
		computer:     computerExecutor,
		gate:         approval.NewGate(store, approvalPolicyFromEnv, approvalGrantTTL),
		store:        store,
		startedAt:    time.Now(),
		state: &crowv1.RuntimeState{
			Status:  "idle",
			Phase:   "idle",
			Title:   "Crow",
			Message: "Ready",
		},
		settings:     settingsFromEnv(),
		executors:    executor.NewRegistry(executors...),
		warnings:     warnings,
		approvals:    map[string]chan bool{},
		taskWatchers: map[string]map[chan *crowv1.TaskEvent]struct{}{},
		cancels:      map[string]context.CancelFunc{},
	}
}

func main() {
	config.LoadDotEnv()

	host := flag.String("host", "127.0.0.1", "listen host")
	port := flag.Int("port", 0, "listen port")
	flag.Parse()

	listener, err := net.Listen("tcp", fmt.Sprintf("%s:%d", *host, *port))
	if err != nil {
		log.Fatalf("listen failed: %v", err)
	}
	defer listener.Close()

	token, err := randomToken()
	if err != nil {
		log.Fatalf("token failed: %v", err)
	}

	storage, err := store.OpenDefault()
	if err != nil {
		log.Fatalf("storage failed: %v", err)
	}
	defer storage.Close()

	runtime := newServer(storage)
	schedulerCtx, stopScheduler := context.WithCancel(context.Background())
	defer stopScheduler()
	go runtime.runReminderScheduler(schedulerCtx, 5*time.Second)
	mux := http.NewServeMux()
	register(mux, runtime, token)

	baseURL := "http://" + listener.Addr().String()
	if err := writeSession(baseURL, token); err != nil {
		log.Fatalf("write session failed: %v", err)
	}
	log.Printf("crowd listening on %s", baseURL)

	httpServer := &http.Server{
		Handler: h2c.NewHandler(mux, &http2.Server{}),
	}

	errs := make(chan error, 1)
	go func() {
		errs <- httpServer.Serve(listener)
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)

	select {
	case <-signals:
	case err := <-errs:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("serve failed: %v", err)
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(ctx)
	_ = removeSession()
}

func register(mux *http.ServeMux, runtime *server, token string) {
	interceptors := connect.WithInterceptors(newAuthInterceptor(token))

	path, handler := crowv1connect.NewCrowRuntimeServiceHandler(runtime, interceptors)
	mux.Handle(path, handler)
	path, handler = crowv1connect.NewTaskServiceHandler(runtime, interceptors)
	mux.Handle(path, handler)
	path, handler = crowv1connect.NewApprovalServiceHandler(runtime, interceptors)
	mux.Handle(path, handler)
	path, handler = crowv1connect.NewSettingsServiceHandler(runtime, interceptors)
	mux.Handle(path, handler)
	path, handler = crowv1connect.NewVoiceServiceHandler(runtime, interceptors)
	mux.Handle(path, handler)
	path, handler = crowv1connect.NewComputerServiceHandler(runtime, interceptors)
	mux.Handle(path, handler)
	path, handler = crowv1connect.NewReminderServiceHandler(runtime, interceptors)
	mux.Handle(path, handler)
	mux.HandleFunc("/v1/executors", runtime.executorsHTTPHandler(token))

	agentHandler := agent.NewHandler(llmProvider, intEnv("CROW_AGENT_MAX_STEPS", agent.DefaultMaxSteps),
		append([]agent.Tool{agent.DelegateToCodexIf(runtime.hasCodeExecutor), agent.UseComputer(computerUseEnabled)},
			append(agent.ReminderTools(reminderAdapter{runtime.store}),
				agent.OpenComputerUseSettings(func() bool { return !computerUseEnabled() }, runtime.openComputerUseSettings))...)...).
		WithMemory(memory.Open(memory.DefaultDir()), func() bool { return boolEnvDefault("CROW_MEMORY_ENABLED", true) }).
		WithConversation(runtime.conversation)
	mux.HandleFunc("/v1/agent/respond", requireSessionToken(token, agentHandler.ServeRespond))
	mux.HandleFunc("/v1/agent/respond-stream", requireSessionToken(token, agentHandler.ServeRespondStream))
}

// llmAPIKeyFromEnv also accepts the legacy CROW_OPENAI_API_KEY for the OpenAI
// provider, matching llm.ConfigFromEnv, so Settings shows the key as set.
func llmAPIKeyFromEnv() string {
	if key := firstNonEmptyEnv("CROW_LLM_API_KEY"); key != "" {
		return key
	}
	if provider := strings.ToLower(firstNonEmptyEnv("CROW_LLM_PROVIDER")); provider == "" || provider == "openai" {
		return firstNonEmptyEnv("CROW_OPENAI_API_KEY")
	}
	return ""
}

func computerUseEnabled() bool { return boolEnvDefault("CROW_COMPUTER_USE_ENABLED", false) }

// llmProvider builds the provider from current settings on every call.
func llmProvider() (llm.Provider, error) {
	return llm.New(llm.ConfigFromEnv())
}

// WatchCommands streams computer-use commands to the app.
func (s *server) WatchCommands(ctx context.Context, req *connect.Request[crowv1.WatchComputerCommandsRequest], stream *connect.ServerStream[crowv1.ComputerCommand]) error {
	commands := s.bridge.Watch(ctx)
	for {
		select {
		case <-ctx.Done():
			return nil
		case cmd := <-commands:
			if err := stream.Send(cmd); err != nil {
				return err
			}
		}
	}
}

func (s *server) SubmitResult(ctx context.Context, req *connect.Request[crowv1.ComputerResult]) (*connect.Response[crowv1.SubmitComputerResultResponse], error) {
	if err := s.bridge.Submit(req.Msg); err != nil {
		return nil, connect.NewError(connect.CodeNotFound, err)
	}
	return connect.NewResponse(&crowv1.SubmitComputerResultResponse{}), nil
}

// Perform runs one computer action for an external agent. Its actions and
// approvals are grouped under a task that records the session in Crow.
func (s *server) Perform(ctx context.Context, req *connect.Request[crowv1.PerformComputerActionRequest]) (*connect.Response[crowv1.PerformComputerActionResponse], error) {
	taskID := strings.TrimSpace(req.Msg.GetTaskId())
	if _, _, _, err := s.store.GetTask(taskID); taskID == "" || err != nil {
		now := time.Now().Format(time.RFC3339)
		task := &crowv1.Task{
			Id:        fmt.Sprintf("task-%d", time.Now().UnixNano()),
			Title:     "External agent: " + firstNonEmpty(req.Msg.GetClient(), "computer use"),
			Kind:      computer.Kind,
			Status:    "completed",
			Subtitle:  "Idle",
			CreatedAt: now,
			UpdatedAt: now,
		}
		if err := s.store.CreateTask(task); err != nil {
			return nil, err
		}
		taskID = task.Id
	}
	text, images, err := s.computer.Perform(ctx, taskID, req.Msg.GetArgsJson(), s)
	if err != nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, err)
	}
	res := &crowv1.PerformComputerActionResponse{TaskId: taskID, Text: text}
	if len(images) > 0 {
		res.Image, res.ImageMediaType = images[0].Data, images[0].MediaType
	}
	return connect.NewResponse(res), nil
}

// hasCodeExecutor reports whether a hand-off to Codex reaches a real executor
// rather than the fallback.
func (s *server) hasCodeExecutor() bool {
	return s.executors.Select(classifyKind("", "agent")).ID() != "mock"
}

// openComputerUseSettings asks the app to show Settings at Computer use. The
// command bridge is connected even while computer use is off.
func (s *server) openComputerUseSettings(ctx context.Context) error {
	res, err := s.bridge.Do(ctx, "open_settings", map[string]any{"section": "computer"})
	if err != nil {
		return err
	}
	if !res.GetOk() {
		return errors.New(res.GetError())
	}
	return nil
}

// runReminderScheduler fires due reminders; the app picks them up from the snapshot.
func (s *server) runReminderScheduler(ctx context.Context, every time.Duration) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		if fired, err := s.store.FireDueReminders(time.Now()); err != nil {
			log.Printf("fire reminders failed: %v", err)
		} else {
			for _, r := range fired {
				log.Printf("reminder %s fired", r.GetId())
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (s *server) ListReminders(ctx context.Context, req *connect.Request[crowv1.ListRemindersRequest]) (*connect.Response[crowv1.ListRemindersResponse], error) {
	reminders, err := s.store.PendingReminders()
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&crowv1.ListRemindersResponse{Reminders: reminders}), nil
}

func (s *server) CancelReminder(ctx context.Context, req *connect.Request[crowv1.ReminderRequest]) (*connect.Response[crowv1.Reminder], error) {
	ok, err := s.store.CancelReminder(req.Msg.GetId())
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("reminder is not pending"))
	}
	return s.reminderResponse(req.Msg.GetId())
}

func (s *server) AckReminder(ctx context.Context, req *connect.Request[crowv1.ReminderRequest]) (*connect.Response[crowv1.Reminder], error) {
	if err := s.store.AckReminder(req.Msg.GetId()); err != nil {
		return nil, err
	}
	return s.reminderResponse(req.Msg.GetId())
}

func (s *server) reminderResponse(id string) (*connect.Response[crowv1.Reminder], error) {
	r, err := s.store.GetReminder(id)
	if err != nil {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("reminder not found"))
	}
	return connect.NewResponse(r), nil
}

// reminderAdapter lets the agent's reminder tools use the SQLite store.
type reminderAdapter struct{ store *store.Store }

func (a reminderAdapter) CreateReminder(text string, dueAt time.Time) (agent.Reminder, error) {
	r, err := a.store.CreateReminder(text, dueAt, time.Now())
	if err != nil {
		return agent.Reminder{}, err
	}
	return agent.Reminder{ID: r.GetId(), Text: r.GetText(), DueAt: dueAt}, nil
}

func (a reminderAdapter) PendingReminders() ([]agent.Reminder, error) {
	reminders, err := a.store.PendingReminders()
	if err != nil {
		return nil, err
	}
	out := make([]agent.Reminder, 0, len(reminders))
	for _, r := range reminders {
		due, _ := time.Parse(time.RFC3339, r.GetDueAt())
		out = append(out, agent.Reminder{ID: r.GetId(), Text: r.GetText(), DueAt: due})
	}
	return out, nil
}

func (a reminderAdapter) CancelReminder(id string) (bool, error) {
	return a.store.CancelReminder(id)
}

func intEnv(key string, fallback int) int {
	if value, err := strconv.Atoi(strings.TrimSpace(os.Getenv(key))); err == nil && value > 0 {
		return value
	}
	return fallback
}

func requireSessionToken(token string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-crow-session-token") != token {
			http.Error(w, "invalid session token", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (s *server) executorsHTTPHandler(token string) http.HandlerFunc {
	type response struct {
		Executors  []executor.Descriptor `json:"executors"`
		ConfigDirs []string              `json:"configDirs"`
		Warnings   []string              `json:"warnings,omitempty"`
	}
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-crow-session-token") != token {
			http.Error(w, "invalid session token", http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		descriptors := s.executors.Descriptors()
		if strings.EqualFold(r.URL.Query().Get("deep"), "1") || strings.EqualFold(r.URL.Query().Get("deep"), "true") {
			ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
			defer cancel()
			descriptors = s.executors.CheckDescriptors(ctx)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(response{
			Executors:  descriptors,
			ConfigDirs: executor.ExecutorAdapterDirs(),
			Warnings:   append([]string{}, s.warnings...),
		})
	}
}

type authInterceptor struct {
	token string
}

func (a authInterceptor) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, request connect.AnyRequest) (connect.AnyResponse, error) {
		if request.Header().Get("x-crow-session-token") != a.token {
			return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("invalid session token"))
		}
		return next(ctx, request)
	}
}

func (a authInterceptor) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return next
}

func (a authInterceptor) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return func(ctx context.Context, conn connect.StreamingHandlerConn) error {
		if conn.RequestHeader().Get("x-crow-session-token") != a.token {
			return connect.NewError(connect.CodeUnauthenticated, errors.New("invalid session token"))
		}
		return next(ctx, conn)
	}
}

func newAuthInterceptor(token string) connect.Interceptor {
	return authInterceptor{token: token}
}

func (s *server) GetSnapshot(ctx context.Context, req *connect.Request[crowv1.GetSnapshotRequest]) (*connect.Response[crowv1.RuntimeSnapshot], error) {
	tasks, err := s.store.ListTasks(20, "")
	if err != nil {
		return nil, err
	}
	approvals, err := s.store.ListPendingApprovals()
	if err != nil {
		return nil, err
	}

	s.mu.Lock()
	state := cloneRuntimeState(s.state)
	state.PendingApprovals = int32(len(approvals))
	s.mu.Unlock()

	due, err := s.store.UnackedReminders()
	if err != nil {
		return nil, err
	}

	return connect.NewResponse(&crowv1.RuntimeSnapshot{
		State:            state,
		RecentTasks:      tasks,
		PendingApprovals: approvals,
		DueReminders:     due,
	}), nil
}

func (s *server) WatchRuntime(ctx context.Context, req *connect.Request[crowv1.WatchRuntimeRequest], stream *connect.ServerStream[crowv1.RuntimeEvent]) error {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	for {
		s.mu.Lock()
		event := &crowv1.RuntimeEvent{
			Id:        fmt.Sprintf("runtime-%d", time.Now().UnixNano()),
			Type:      "runtime.snapshot",
			State:     cloneRuntimeState(s.state),
			CreatedAt: time.Now().Format(time.RFC3339),
		}
		s.mu.Unlock()

		if err := stream.Send(event); err != nil {
			return err
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func (s *server) CreateTask(ctx context.Context, req *connect.Request[crowv1.CreateTaskRequest]) (*connect.Response[crowv1.Task], error) {
	command := req.Msg.GetCommand()
	if command == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("command is required"))
	}

	now := time.Now().Format(time.RFC3339)
	task := &crowv1.Task{
		Id:        fmt.Sprintf("task-%d", time.Now().UnixNano()),
		Title:     command,
		Kind:      classifyKind(command, req.Msg.GetMode()),
		Status:    "running",
		Subtitle:  "Starting",
		CreatedAt: now,
		UpdatedAt: now,
	}
	event := &crowv1.TaskEvent{
		Id:        fmt.Sprintf("event-%d", time.Now().UnixNano()),
		TaskId:    task.Id,
		Type:      "task.created",
		Title:     "Task created",
		Message:   "Crow accepted the command.",
		CreatedAt: now,
	}

	if err := s.store.CreateTask(task, event); err != nil {
		return nil, err
	}
	s.publishTaskEvent(event)

	s.mu.Lock()
	s.state = &crowv1.RuntimeState{
		Status:       "running",
		Phase:        "running",
		Title:        "Task started",
		Message:      command,
		ActiveTaskId: task.Id,
	}
	taskCtx, cancel := context.WithCancel(context.Background())
	s.cancels[task.Id] = cancel
	s.mu.Unlock()

	go func() {
		defer func() {
			s.mu.Lock()
			delete(s.cancels, task.Id)
			s.mu.Unlock()
			cancel()
			s.gate.ForgetTask(task.Id)
		}()
		s.runTask(taskCtx, task, command)
	}()

	return connect.NewResponse(task), nil
}

func (s *server) runTask(ctx context.Context, task *crowv1.Task, command string) {
	event := &crowv1.TaskEvent{
		Id:        fmt.Sprintf("event-%d", time.Now().UnixNano()),
		TaskId:    task.Id,
		Type:      "task.started",
		Title:     "Task started",
		Message:   "Crow is preparing execution.",
		CreatedAt: time.Now().Format(time.RFC3339),
	}
	if err := s.store.AddEvent(event, "running", "Running", event.CreatedAt); err == nil {
		s.publishTaskEvent(event)
	}
	for _, warning := range s.warnings {
		_ = s.ApplyExecutorEvent(ctx, task.Id, executor.Event{
			Type:     "executor.warning",
			Title:    "Executor adapter warning",
			Message:  warning,
			Status:   "running",
			Subtitle: "Executor adapter warning",
		})
	}

	selected := s.executors.Select(task.Kind)
	if selected.ID() != "mock" {
		_ = s.ApplyExecutorEvent(ctx, task.Id, executor.Event{
			Type:     "executor.selected",
			Title:    "Executor selected",
			Message:  selected.ID(),
			Status:   "running",
			Subtitle: "Routing task",
		})
	}
	if err := selected.Run(ctx, executor.Request{
		TaskID:  task.Id,
		Kind:    task.Kind,
		Command: command,
	}, s); err != nil {
		if ctx.Err() != nil {
			_ = s.ApplyExecutorEvent(context.WithoutCancel(ctx), task.Id, executor.Event{
				Type:     "task.cancelled",
				Title:    "Task cancelled",
				Message:  "Stopped by the user.",
				Status:   "cancelled",
				Subtitle: "Cancelled",
			})
			return
		}
		_ = s.ApplyExecutorEvent(ctx, task.Id, executor.Event{
			Type:     "task.failed",
			Title:    "Executor failed",
			Message:  err.Error(),
			Status:   "failed",
			Subtitle: "Failed",
		})
	}
}

func (s *server) ApplyExecutorEvent(ctx context.Context, taskID string, event executor.Event) error {
	eventType := strings.TrimSpace(event.Type)
	if eventType == "" {
		eventType = "executor.output"
	}
	title := firstNonEmpty(event.Title, "Executor event")
	message := strings.TrimSpace(event.Message)
	status := strings.TrimSpace(event.Status)
	subtitle := strings.TrimSpace(event.Subtitle)
	if status == "" || subtitle == "" {
		inferredStatus, inferredSubtitle := inferExecutorTaskState(eventType, title, message)
		if status == "" {
			status = inferredStatus
		}
		if subtitle == "" {
			subtitle = inferredSubtitle
		}
	}

	now := time.Now().Format(time.RFC3339)
	taskEvent := &crowv1.TaskEvent{
		Id:        fmt.Sprintf("event-%d", time.Now().UnixNano()),
		TaskId:    taskID,
		Type:      eventType,
		Title:     title,
		Message:   message,
		CreatedAt: now,
	}
	if err := s.store.AddEvent(taskEvent, status, subtitle, now); err != nil {
		return err
	}
	s.publishTaskEvent(taskEvent)
	s.noteTaskOutcome(eventType, message)

	if eventType == "approval.required" {
		approval := &crowv1.Approval{
			Id:             fmt.Sprintf("approval-%d", time.Now().UnixNano()),
			TaskId:         taskID,
			Title:          firstNonEmpty(event.ApprovalTitle, title),
			Description:    message,
			RiskLevel:      event.ApprovalRisk,
			ProposedAction: firstNonEmpty(event.ApprovalAction, title),
			Preview:        event.ApprovalPreview,
			Status:         "pending",
			CreatedAt:      now,
		}
		if approval.RiskLevel == 0 {
			approval.RiskLevel = 2
		}
		if err := s.store.CreateApproval(approval); err != nil {
			return err
		}
	}

	s.mu.Lock()
	s.state = &crowv1.RuntimeState{
		Status:       status,
		Phase:        phaseForStatus(status, eventType),
		Title:        title,
		Message:      message,
		ActiveTaskId: taskID,
	}
	s.mu.Unlock()
	return nil
}

func (s *server) RequestApproval(ctx context.Context, taskID string, request executor.ApprovalRequest) (bool, error) {
	scope := approval.Scope(firstNonEmpty(request.Scope, string(approval.ScopeCodex)))
	if allowed, policy := s.gate.Allowed(taskID, scope); allowed {
		_ = s.ApplyExecutorEvent(ctx, taskID, executor.Event{
			Type:     "approval.auto",
			Title:    "Allowed by approval policy",
			Message:  fmt.Sprintf("%s (%s: %s)", firstNonEmpty(request.Action, request.Tool, "Action"), scope, policy),
			Status:   "running",
			Subtitle: "Approved",
		})
		return true, nil
	}
	approved, err := s.askApproval(ctx, taskID, request)
	if err == nil {
		if recordErr := s.gate.Record(taskID, scope, approved); recordErr != nil {
			log.Printf("record approval grant failed: %v", recordErr)
		}
	}
	return approved, err
}

func approvalPolicyFromEnv(scope approval.Scope) approval.Policy {
	return approval.ParsePolicy(scope, os.Getenv("CROW_APPROVAL_"+strings.ToUpper(string(scope))))
}

func approvalGrantTTL() time.Duration {
	return time.Duration(intEnv("CROW_APPROVAL_GRANT_MINUTES", int(approval.DefaultGrantTTL/time.Minute))) * time.Minute
}

func (s *server) ListGrants(ctx context.Context, req *connect.Request[crowv1.ListGrantsRequest]) (*connect.Response[crowv1.ListGrantsResponse], error) {
	grants, err := s.store.ActiveGrants(time.Now())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&crowv1.ListGrantsResponse{Grants: grants}), nil
}

func (s *server) RevokeGrants(ctx context.Context, req *connect.Request[crowv1.RevokeGrantsRequest]) (*connect.Response[crowv1.ListGrantsResponse], error) {
	if err := s.store.RevokeGrants(strings.TrimSpace(req.Msg.GetScope())); err != nil {
		return nil, err
	}
	return s.ListGrants(ctx, connect.NewRequest(&crowv1.ListGrantsRequest{}))
}

// askApproval shows an approval prompt and waits for the user's decision.
func (s *server) askApproval(ctx context.Context, taskID string, request executor.ApprovalRequest) (bool, error) {
	now := time.Now().Format(time.RFC3339)
	approvalID := fmt.Sprintf("approval-%d", time.Now().UnixNano())
	waiter := make(chan bool, 1)

	s.mu.Lock()
	s.approvals[approvalID] = waiter
	s.mu.Unlock()
	defer s.unregisterApprovalWaiter(approvalID)

	approval := &crowv1.Approval{
		Id:             approvalID,
		TaskId:         taskID,
		Title:          firstNonEmpty(request.Action, request.Tool, "Approval Required"),
		Description:    firstNonEmpty(request.Description, "Crow needs your approval to continue."),
		RiskLevel:      request.RiskLevel,
		ProposedAction: firstNonEmpty(request.Action, request.Tool, "Continue"),
		Preview:        request.Preview,
		Status:         "pending",
		CreatedAt:      now,
	}
	if approval.RiskLevel == 0 {
		approval.RiskLevel = 2
	}
	if err := s.store.CreateApproval(approval); err != nil {
		return false, err
	}
	approvalEvent := &crowv1.TaskEvent{
		Id:        fmt.Sprintf("event-%d", time.Now().UnixNano()),
		TaskId:    taskID,
		Type:      "approval.required",
		Title:     "Approval Required",
		Message:   approval.Description,
		CreatedAt: now,
	}
	if err := s.store.AddEvent(approvalEvent, "waiting_approval", "Approval Required", now); err != nil {
		return false, err
	}
	s.publishTaskEvent(approvalEvent)

	s.mu.Lock()
	s.state = &crowv1.RuntimeState{
		Status:           "waiting_approval",
		Phase:            "approval",
		Title:            "Approval Required",
		Message:          approval.ProposedAction,
		ActiveTaskId:     taskID,
		PendingApprovals: 1,
	}
	s.mu.Unlock()

	select {
	case <-ctx.Done():
		// Clear the prompt so the island does not keep asking for a cancelled task.
		_, _ = s.store.DecideApproval(approvalID, false, "cancelled")
		return false, ctx.Err()
	case approved := <-waiter:
		return approved, nil
	}
}

func (s *server) notifyApprovalDecision(approvalID string, approved bool) {
	s.mu.Lock()
	waiter := s.approvals[approvalID]
	if waiter != nil {
		delete(s.approvals, approvalID)
	}
	s.mu.Unlock()
	if waiter != nil {
		waiter <- approved
	}
}

func (s *server) unregisterApprovalWaiter(approvalID string) {
	s.mu.Lock()
	delete(s.approvals, approvalID)
	s.mu.Unlock()
}

// noteTaskOutcome adds a finished task's result to the conversation context.
func (s *server) noteTaskOutcome(eventType, message string) {
	if s.conversation == nil {
		return
	}
	switch eventType {
	case "task.completed":
		s.conversation.Add("assistant", "[Task result] "+message)
	case "task.failed", "executor.failed":
		s.conversation.Add("assistant", "[Task failed] "+message)
	case "task.cancelled":
		s.conversation.Add("assistant", "[Task cancelled by the user]")
	}
}

func inferExecutorTaskState(eventType string, title string, message string) (string, string) {
	switch eventType {
	case "task.completed":
		return "completed", firstNonEmpty(title, "Task completed")
	case "task.failed", "executor.failed":
		return "failed", firstNonEmpty(title, "Task failed")
	case "approval.required":
		return "waiting_approval", "Approval Required"
	default:
		return "running", firstNonEmpty(title, message, "Executor running")
	}
}

func phaseForStatus(status string, eventType string) string {
	switch {
	case eventType == "approval.required" || status == "waiting_approval":
		return "approval"
	case status == "completed":
		return "completed"
	case status == "failed" || status == "cancelled":
		return "failed"
	default:
		return "running"
	}
}

func (s *server) GetTask(ctx context.Context, req *connect.Request[crowv1.GetTaskRequest]) (*connect.Response[crowv1.TaskDetail], error) {
	task, events, approval, err := s.store.GetTask(req.Msg.GetTaskId())
	if err != nil {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("task not found"))
	}
	return connect.NewResponse(&crowv1.TaskDetail{
		Task:            task,
		Events:          events,
		PendingApproval: approval,
	}), nil
}

func (s *server) CancelTask(ctx context.Context, req *connect.Request[crowv1.CancelTaskRequest]) (*connect.Response[crowv1.Task], error) {
	taskID := req.Msg.GetTaskId()
	s.mu.Lock()
	cancel := s.cancels[taskID]
	s.mu.Unlock()
	if cancel == nil {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("task is not running"))
	}
	cancel()
	task, _, _, err := s.store.GetTask(taskID)
	if err != nil {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("task not found"))
	}
	return connect.NewResponse(task), nil
}

func (s *server) ListTasks(ctx context.Context, req *connect.Request[crowv1.ListTasksRequest]) (*connect.Response[crowv1.ListTasksResponse], error) {
	limit := int(req.Msg.GetLimit())
	tasks, err := s.store.ListTasks(limit, req.Msg.GetStatus())
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&crowv1.ListTasksResponse{Tasks: tasks}), nil
}

func (s *server) WatchTask(ctx context.Context, req *connect.Request[crowv1.WatchTaskRequest], stream *connect.ServerStream[crowv1.TaskEvent]) error {
	taskID := strings.TrimSpace(req.Msg.GetTaskId())
	if taskID == "" {
		return connect.NewError(connect.CodeInvalidArgument, errors.New("task_id is required"))
	}
	ch := s.subscribeTask(taskID)
	defer s.unsubscribeTask(taskID, ch)

	events, err := s.store.ListTaskEvents(taskID)
	if err != nil {
		return err
	}
	sent := map[string]struct{}{}
	for _, event := range events {
		sent[event.GetId()] = struct{}{}
		if err := stream.Send(event); err != nil {
			return err
		}
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case event := <-ch:
			if _, ok := sent[event.GetId()]; ok {
				continue
			}
			sent[event.GetId()] = struct{}{}
			if err := stream.Send(event); err != nil {
				return err
			}
		}
	}
}

func (s *server) subscribeTask(taskID string) chan *crowv1.TaskEvent {
	ch := make(chan *crowv1.TaskEvent, 64)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.taskWatchers[taskID] == nil {
		s.taskWatchers[taskID] = map[chan *crowv1.TaskEvent]struct{}{}
	}
	s.taskWatchers[taskID][ch] = struct{}{}
	return ch
}

func (s *server) unsubscribeTask(taskID string, ch chan *crowv1.TaskEvent) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if watchers := s.taskWatchers[taskID]; watchers != nil {
		delete(watchers, ch)
		if len(watchers) == 0 {
			delete(s.taskWatchers, taskID)
		}
	}
	close(ch)
}

func (s *server) publishTaskEvent(event *crowv1.TaskEvent) {
	if event == nil || event.GetTaskId() == "" {
		return
	}
	s.mu.Lock()
	watchers := make([]chan *crowv1.TaskEvent, 0, len(s.taskWatchers[event.GetTaskId()]))
	for ch := range s.taskWatchers[event.GetTaskId()] {
		watchers = append(watchers, ch)
	}
	s.mu.Unlock()

	for _, ch := range watchers {
		select {
		case ch <- cloneTaskEvent(event):
		default:
		}
	}
}

func (s *server) ListPendingApprovals(ctx context.Context, req *connect.Request[crowv1.ListPendingApprovalsRequest]) (*connect.Response[crowv1.ListPendingApprovalsResponse], error) {
	approvals, err := s.store.ListPendingApprovals()
	if err != nil {
		return nil, err
	}
	return connect.NewResponse(&crowv1.ListPendingApprovalsResponse{Approvals: approvals}), nil
}

func (s *server) DecideApproval(ctx context.Context, req *connect.Request[crowv1.DecideApprovalRequest]) (*connect.Response[crowv1.Approval], error) {
	approval, err := s.store.DecideApproval(req.Msg.GetApprovalId(), req.Msg.GetApproved(), req.Msg.GetReason())
	if err != nil {
		return nil, connect.NewError(connect.CodeNotFound, errors.New("approval not found"))
	}
	s.notifyApprovalDecision(approval.Id, req.Msg.GetApproved())
	return connect.NewResponse(approval), nil
}

func (s *server) GetSettings(ctx context.Context, req *connect.Request[crowv1.GetSettingsRequest]) (*connect.Response[crowv1.Settings], error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return connect.NewResponse(publicSettings(s.settings)), nil
}

func (s *server) SaveSettings(ctx context.Context, req *connect.Request[crowv1.SaveSettingsRequest]) (*connect.Response[crowv1.Settings], error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := cloneSettings(req.Msg.GetSettings())
	// An empty key keeps the stored one for the same provider; the client never sees it.
	if strings.TrimSpace(next.GetLlmApiKey()) == "" && next.GetLlmProvider() == s.settings.GetLlmProvider() {
		next.LlmApiKey = s.settings.GetLlmApiKey()
	}
	s.settings = next
	applySettingsToEnv(s.settings)
	return connect.NewResponse(publicSettings(s.settings)), nil
}

func settingsFromEnv() *crowv1.Settings {
	settings := &crowv1.Settings{
		SttLanguage:            firstNonEmptyEnv("CROW_STT_LANGUAGE"),
		TtsProvider:            firstNonEmptyEnv("CROW_TTS_PROVIDER"),
		TtsVoice:               firstNonEmptyEnv("CROW_OPENAI_TTS_VOICE", "CROW_TTS_VOICE"),
		TtsStreaming:           boolEnvDefault("CROW_TTS_STREAMING", true),
		IslandScreen:           firstNonEmptyEnv("CROW_ISLAND_SCREEN"),
		IslandHotkey:           firstNonEmptyEnv("CROW_ISLAND_HOTKEY"),
		IslandIdleCloseSeconds: firstNonEmptyEnv("CROW_ISLAND_IDLE_CLOSE_SECONDS"),
		AgentMode:              firstNonEmptyEnv("CROW_AGENT_MODE"),
		LlmProvider:            firstNonEmptyEnv("CROW_LLM_PROVIDER"),
		LlmBaseUrl:             firstNonEmptyEnv("CROW_LLM_BASE_URL"),
		LlmModel:               firstNonEmptyEnv("CROW_LLM_MODEL"),
		LlmApiKey:              llmAPIKeyFromEnv(),
		MemoryEnabled:          boolEnvDefault("CROW_MEMORY_ENABLED", true),
		ApprovalComputer:       firstNonEmptyEnv("CROW_APPROVAL_COMPUTER"),
		ApprovalTerminal:       firstNonEmptyEnv("CROW_APPROVAL_TERMINAL"),
		ApprovalCodex:          firstNonEmptyEnv("CROW_APPROVAL_CODEX"),
		ApprovalFileWrite:      firstNonEmptyEnv("CROW_APPROVAL_FILE_WRITE"),
		ComputerSeeOnly:        boolEnvDefault("CROW_COMPUTER_SEE_ONLY", false),
		ComputerUseEnabled:     computerUseEnabled(),
	}
	applyRuntimeSettingsFile(settings)
	applySettingsToEnv(settings)
	return settings
}

func applySettingsToEnv(settings *crowv1.Settings) {
	if settings == nil {
		return
	}
	setEnvIfPresent("CROW_STT_LANGUAGE", settings.GetSttLanguage())
	setEnvIfPresent("CROW_TTS_PROVIDER", settings.GetTtsProvider())
	setEnvIfPresent("CROW_TTS_VOICE", settings.GetTtsVoice())
	setEnvIfPresent("CROW_OPENAI_TTS_VOICE", settings.GetTtsVoice())
	_ = os.Setenv("CROW_TTS_STREAMING", boolString(settings.GetTtsStreaming()))
	setEnvIfPresent("CROW_ISLAND_SCREEN", settings.GetIslandScreen())
	setEnvIfPresent("CROW_ISLAND_HOTKEY", settings.GetIslandHotkey())
	setEnvIfPresent("CROW_ISLAND_IDLE_CLOSE_SECONDS", settings.GetIslandIdleCloseSeconds())
	setEnvIfPresent("CROW_AGENT_MODE", settings.GetAgentMode())
	setEnvIfPresent("CROW_LLM_PROVIDER", settings.GetLlmProvider())
	setEnvIfPresent("CROW_LLM_BASE_URL", settings.GetLlmBaseUrl())
	setEnvIfPresent("CROW_LLM_MODEL", settings.GetLlmModel())
	setEnvIfPresent("CROW_LLM_API_KEY", settings.GetLlmApiKey())
	_ = os.Setenv("CROW_MEMORY_ENABLED", boolString(settings.GetMemoryEnabled()))
	setEnvIfPresent("CROW_APPROVAL_COMPUTER", settings.GetApprovalComputer())
	setEnvIfPresent("CROW_APPROVAL_TERMINAL", settings.GetApprovalTerminal())
	setEnvIfPresent("CROW_APPROVAL_CODEX", settings.GetApprovalCodex())
	setEnvIfPresent("CROW_APPROVAL_FILE_WRITE", settings.GetApprovalFileWrite())
	_ = os.Setenv("CROW_COMPUTER_SEE_ONLY", boolString(settings.GetComputerSeeOnly()))
	_ = os.Setenv("CROW_COMPUTER_USE_ENABLED", boolString(settings.GetComputerUseEnabled()))
}

func setEnvIfPresent(key string, value string) {
	value = strings.TrimSpace(value)
	if value == "" {
		_ = os.Unsetenv(key)
		return
	}
	_ = os.Setenv(key, value)
}

func boolEnvDefault(key string, fallback bool) bool {
	value := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if value == "" {
		return fallback
	}
	return value == "1" || value == "true" || value == "yes" || value == "on"
}

func boolString(value bool) string {
	if value {
		return "true"
	}
	return "false"
}

func applyRuntimeSettingsFile(settings *crowv1.Settings) {
	if settings == nil {
		return
	}
	path := runtimeSettingsPath()
	if path == "" {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	values := map[string]string{}
	if err := json.Unmarshal(data, &values); err != nil {
		return
	}
	applyRuntimeSettingValues(settings, values)
}

func runtimeSettingsPath() string {
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "Crow", "runtime-settings.json")
}

func applyRuntimeSettingValues(settings *crowv1.Settings, values map[string]string) {
	if value := strings.TrimSpace(values["CROW_STT_LANGUAGE"]); value != "" {
		settings.SttLanguage = value
	}
	if value := strings.TrimSpace(values["CROW_TTS_PROVIDER"]); value != "" {
		settings.TtsProvider = value
	}
	if value := strings.TrimSpace(firstNonEmpty(values["CROW_OPENAI_TTS_VOICE"], values["CROW_TTS_VOICE"])); value != "" {
		settings.TtsVoice = value
	}
	if value, ok := values["CROW_TTS_STREAMING"]; ok {
		settings.TtsStreaming = parseBoolSetting(value, settings.TtsStreaming)
	}
	if value := strings.TrimSpace(values["CROW_ISLAND_SCREEN"]); value != "" {
		settings.IslandScreen = value
	}
	if value := strings.TrimSpace(values["CROW_ISLAND_HOTKEY"]); value != "" {
		settings.IslandHotkey = value
	}
	if value := strings.TrimSpace(values["CROW_ISLAND_IDLE_CLOSE_SECONDS"]); value != "" {
		settings.IslandIdleCloseSeconds = value
	}
	// The API key is never stored in runtime-settings.json.
	if value := strings.TrimSpace(values["CROW_AGENT_MODE"]); value != "" {
		settings.AgentMode = value
	}
	if value := strings.TrimSpace(values["CROW_LLM_PROVIDER"]); value != "" {
		settings.LlmProvider = value
	}
	if value := strings.TrimSpace(values["CROW_LLM_BASE_URL"]); value != "" {
		settings.LlmBaseUrl = value
	}
	if value := strings.TrimSpace(values["CROW_LLM_MODEL"]); value != "" {
		settings.LlmModel = value
	}
	if value, ok := values["CROW_MEMORY_ENABLED"]; ok {
		settings.MemoryEnabled = parseBoolSetting(value, settings.MemoryEnabled)
	}
	if value, ok := values["CROW_COMPUTER_USE_ENABLED"]; ok {
		settings.ComputerUseEnabled = parseBoolSetting(value, settings.ComputerUseEnabled)
	}
	if value, ok := values["CROW_COMPUTER_SEE_ONLY"]; ok {
		settings.ComputerSeeOnly = parseBoolSetting(value, settings.ComputerSeeOnly)
	}
	for key, field := range map[string]*string{
		"CROW_APPROVAL_COMPUTER":   &settings.ApprovalComputer,
		"CROW_APPROVAL_TERMINAL":   &settings.ApprovalTerminal,
		"CROW_APPROVAL_CODEX":      &settings.ApprovalCodex,
		"CROW_APPROVAL_FILE_WRITE": &settings.ApprovalFileWrite,
	} {
		if value := strings.TrimSpace(values[key]); value != "" {
			*field = value
		}
	}
}

func parseBoolSetting(value string, fallback bool) bool {
	switch strings.TrimSpace(strings.ToLower(value)) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
	}
}

func (s *server) StartVoiceSession(ctx context.Context, req *connect.Request[crowv1.StartVoiceSessionRequest]) (*connect.Response[crowv1.VoiceSession], error) {
	return connect.NewResponse(&crowv1.VoiceSession{
		Id:        fmt.Sprintf("voice-%d", time.Now().UnixNano()),
		Status:    "started",
		CreatedAt: time.Now().Format(time.RFC3339),
	}), nil
}

func (s *server) StreamAudio(ctx context.Context, stream *connect.BidiStream[crowv1.AudioChunk, crowv1.VoiceEvent]) error {
	for {
		chunk, err := stream.Receive()
		if err != nil {
			return err
		}
		if chunk.GetFinal() {
			return stream.Send(&crowv1.VoiceEvent{
				Id:        fmt.Sprintf("voice-event-%d", time.Now().UnixNano()),
				SessionId: chunk.GetSessionId(),
				Type:      "voice.transcript.final",
				Text:      "",
				Final:     true,
				CreatedAt: time.Now().Format(time.RFC3339),
			})
		}
	}
}

// PolishTranscript cleans up a dictation transcript. Without a usable model the
// transcript comes back unchanged, so dictation still types something.
func (s *server) PolishTranscript(ctx context.Context, req *connect.Request[crowv1.PolishTranscriptRequest]) (*connect.Response[crowv1.PolishTranscriptResponse], error) {
	raw := strings.TrimSpace(req.Msg.GetText())
	unchanged := connect.NewResponse(&crowv1.PolishTranscriptResponse{Text: raw})
	if raw == "" {
		return unchanged, nil
	}
	provider, err := llmProvider()
	if err != nil {
		log.Printf("polish transcript: %v", err)
		return unchanged, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	text, err := dictation.Polish(ctx, provider, raw, req.Msg.GetApp(), req.Msg.GetVocabulary())
	if err != nil {
		log.Printf("polish transcript: %v", err)
		return unchanged, nil
	}
	return connect.NewResponse(&crowv1.PolishTranscriptResponse{Text: text, Polished: true}), nil
}

func (s *server) CancelVoiceSession(ctx context.Context, req *connect.Request[crowv1.CancelVoiceSessionRequest]) (*connect.Response[crowv1.CancelVoiceSessionResponse], error) {
	return connect.NewResponse(&crowv1.CancelVoiceSessionResponse{Cancelled: true}), nil
}

func writeSession(baseURL string, token string) error {
	dir, err := runtimeDir()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(sessionFile{
		PID:       os.Getpid(),
		BaseURL:   baseURL,
		Token:     token,
		StartedAt: time.Now().Format(time.RFC3339),
	}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "session.json"), data, 0o600)
}

func removeSession() error {
	dir, err := runtimeDir()
	if err != nil {
		return err
	}
	return os.Remove(filepath.Join(dir, "session.json"))
}

func runtimeDir() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "Crow", "runtime"), nil
}

func randomToken() (string, error) {
	var bytes [32]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes[:]), nil
}

func classifyKind(command string, mode string) string {
	mode = strings.ToLower(strings.TrimSpace(mode))
	if mode == "agent" {
		return "agent"
	}
	if mode == computer.Kind {
		return computer.Kind
	}
	value := strings.ToLower(command + " " + mode)
	switch {
	case containsAny(value, "email", "mail", "邮件", "邮箱", "未读"):
		return "email"
	case containsAny(value, "code", "codex", "代码", "项目", "bug", "修复"):
		return "code"
	case containsAny(value, "browser", "web", "网页", "浏览器"):
		return "browser"
	case containsAny(value, "research", "调研"):
		return "research"
	default:
		return "general"
	}
}

func containsAny(value string, needles ...string) bool {
	for _, needle := range needles {
		if needle != "" && strings.Contains(value, strings.ToLower(needle)) {
			return true
		}
	}
	return false
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			return value
		}
	}
	return ""
}

func firstNonEmptyEnv(keys ...string) string {
	for _, key := range keys {
		if value := strings.TrimSpace(os.Getenv(key)); value != "" {
			return value
		}
	}
	return ""
}

func cloneRuntimeState(state *crowv1.RuntimeState) *crowv1.RuntimeState {
	if state == nil {
		return nil
	}
	return &crowv1.RuntimeState{
		Status:           state.Status,
		Phase:            state.Phase,
		Title:            state.Title,
		Message:          state.Message,
		ActiveTaskId:     state.ActiveTaskId,
		PendingApprovals: state.PendingApprovals,
		VoiceListening:   state.VoiceListening,
		VoiceSpeaking:    state.VoiceSpeaking,
	}
}

func cloneTask(task *crowv1.Task) *crowv1.Task {
	if task == nil {
		return nil
	}
	return &crowv1.Task{
		Id:        task.Id,
		Title:     task.Title,
		Kind:      task.Kind,
		Status:    task.Status,
		Subtitle:  task.Subtitle,
		CreatedAt: task.CreatedAt,
		UpdatedAt: task.UpdatedAt,
	}
}

func cloneTasks(tasks []*crowv1.Task) []*crowv1.Task {
	cloned := make([]*crowv1.Task, 0, len(tasks))
	for _, task := range tasks {
		cloned = append(cloned, cloneTask(task))
	}
	return cloned
}

func cloneEvents(events []*crowv1.TaskEvent) []*crowv1.TaskEvent {
	cloned := make([]*crowv1.TaskEvent, 0, len(events))
	for _, event := range events {
		cloned = append(cloned, cloneTaskEvent(event))
	}
	return cloned
}

func cloneTaskEvent(event *crowv1.TaskEvent) *crowv1.TaskEvent {
	if event == nil {
		return nil
	}
	return &crowv1.TaskEvent{
		Id:        event.Id,
		TaskId:    event.TaskId,
		Type:      event.Type,
		Title:     event.Title,
		Message:   event.Message,
		CreatedAt: event.CreatedAt,
	}
}

func cloneSettings(settings *crowv1.Settings) *crowv1.Settings {
	if settings == nil {
		return &crowv1.Settings{}
	}
	return proto.Clone(settings).(*crowv1.Settings)
}

// publicSettings hides the API key and reports only whether one is set.
func publicSettings(settings *crowv1.Settings) *crowv1.Settings {
	out := cloneSettings(settings)
	out.LlmApiKeySet = strings.TrimSpace(out.GetLlmApiKey()) != ""
	out.LlmApiKey = ""
	return out
}
