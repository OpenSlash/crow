package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"connectrpc.com/connect"
	crowv1 "github.com/crow/crow/apps/daemon/gen/crow/v1"
	"github.com/crow/crow/apps/daemon/gen/crow/v1/crowv1connect"
)

type sessionFile struct {
	PID       int    `json:"pid"`
	BaseURL   string `json:"baseURL"`
	Token     string `json:"token"`
	StartedAt string `json:"startedAt"`
}

func main() {
	command := flag.String("create-task", "", "create a task")
	mode := flag.String("mode", "cli", "task mode")
	taskID := flag.String("task-id", "", "show task detail")
	watch := flag.Bool("watch", false, "watch task events until terminal state")
	timeout := flag.Duration("timeout", 60*time.Second, "request/watch timeout")
	flag.Parse()

	session, err := readSession()
	if err != nil {
		log.Fatal(err)
	}

	client := crowv1connect.NewTaskServiceClient(http.DefaultClient, session.BaseURL)
	runtimeClient := crowv1connect.NewCrowRuntimeServiceClient(http.DefaultClient, session.BaseURL)

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	createdTaskID := ""
	if *command != "" {
		res, err := client.CreateTask(ctx, withToken(connect.NewRequest(&crowv1.CreateTaskRequest{
			Command: *command,
			Mode:    *mode,
		}), session.Token))
		if err != nil {
			log.Fatal(err)
		}
		createdTaskID = res.Msg.GetId()
		fmt.Printf("created task: %s %s\n", createdTaskID, res.Msg.GetTitle())
	}

	targetTaskID := strings.TrimSpace(*taskID)
	if targetTaskID == "" {
		targetTaskID = createdTaskID
	}

	if *watch {
		if targetTaskID == "" {
			log.Fatal("--watch requires --task-id or --create-task")
		}
		if err := watchTask(ctx, client, session.Token, targetTaskID); err != nil {
			log.Fatal(err)
		}
	}

	if targetTaskID != "" {
		detail, err := client.GetTask(ctx, withToken(connect.NewRequest(&crowv1.GetTaskRequest{TaskId: targetTaskID}), session.Token))
		if err != nil {
			log.Fatal(err)
		}
		printTaskDetail(detail.Msg)
	}

	snapshot, err := runtimeClient.GetSnapshot(ctx, withToken(connect.NewRequest(&crowv1.GetSnapshotRequest{}), session.Token))
	if err != nil {
		log.Fatal(err)
	}
	state := snapshot.Msg.GetState()
	fmt.Printf("state: %s/%s %s\n", state.GetStatus(), state.GetPhase(), state.GetTitle())
	fmt.Printf("tasks: %d\n", len(snapshot.Msg.GetRecentTasks()))
	fmt.Printf("approvals: %d\n", len(snapshot.Msg.GetPendingApprovals()))
}

func watchTask(ctx context.Context, client crowv1connect.TaskServiceClient, token string, taskID string) error {
	stream, err := client.WatchTask(ctx, withToken(connect.NewRequest(&crowv1.WatchTaskRequest{TaskId: taskID}), token))
	if err != nil {
		return err
	}
	for stream.Receive() {
		event := stream.Msg()
		fmt.Printf("event: %s %s", event.GetType(), event.GetTitle())
		if message := strings.TrimSpace(event.GetMessage()); message != "" {
			fmt.Printf(" | %s", message)
		}
		fmt.Println()
		switch event.GetType() {
		case "task.completed", "task.failed", "approval.required":
			return nil
		}
	}
	return stream.Err()
}

func printTaskDetail(detail *crowv1.TaskDetail) {
	task := detail.GetTask()
	fmt.Printf("task: %s %s/%s %s\n", task.GetId(), task.GetStatus(), task.GetKind(), task.GetTitle())
	for _, event := range detail.GetEvents() {
		fmt.Printf("- %s %s: %s\n", event.GetType(), event.GetTitle(), event.GetMessage())
	}
	if approval := detail.GetPendingApproval(); approval != nil {
		fmt.Printf("approval: %s %s risk=%d\n", approval.GetId(), approval.GetProposedAction(), approval.GetRiskLevel())
	}
}

func withToken[T any](req *connect.Request[T], token string) *connect.Request[T] {
	req.Header().Set("x-crow-session-token", token)
	return req
}

func readSession() (sessionFile, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return sessionFile{}, err
	}
	data, err := os.ReadFile(filepath.Join(base, "Crow", "runtime", "session.json"))
	if err != nil {
		return sessionFile{}, err
	}
	var session sessionFile
	if err := json.Unmarshal(data, &session); err != nil {
		return sessionFile{}, err
	}
	return session, nil
}
