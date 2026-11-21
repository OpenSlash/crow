package main

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	crowv1 "github.com/crow/crow/apps/daemon/gen/crow/v1"
	"github.com/crow/crow/apps/daemon/internal/executor"
	"github.com/crow/crow/apps/daemon/internal/store"
)

func newTestServer(t *testing.T) *server {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	st, err := store.Open(filepath.Join(t.TempDir(), "crow.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	s := newServer(st)
	now := time.Now().Format(time.RFC3339)
	for _, id := range []string{"t1", "t2"} {
		if err := st.CreateTask(&crowv1.Task{Id: id, Title: id, Kind: "code", Status: "running", Subtitle: "", CreatedAt: now, UpdatedAt: now}); err != nil {
			t.Fatal(err)
		}
	}
	return s
}

// decide answers the next approval prompt and reports whether one appeared.
func decide(s *server, approved bool) <-chan bool {
	asked := make(chan bool, 1)
	go func() {
		for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
			s.mu.Lock()
			var id string
			for key := range s.approvals {
				id = key
			}
			s.mu.Unlock()
			if id != "" {
				s.notifyApprovalDecision(id, approved)
				asked <- true
				return
			}
		}
		asked <- false
	}()
	return asked
}

func request(t *testing.T, s *server, task, scope string) bool {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ok, err := s.RequestApproval(ctx, task, executor.ApprovalRequest{Scope: scope, Action: "act"})
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

func TestApprovalPolicies(t *testing.T) {
	s := newTestServer(t)
	t.Setenv("CROW_APPROVAL_EXECUTOR", "never")
	t.Setenv("CROW_APPROVAL_FILE_WRITE", "once")
	t.Setenv("CROW_APPROVAL_TERMINAL", "never") // raised to once

	if !request(t, s, "t1", "codex") {
		t.Fatal("never policy should auto-approve")
	}

	// once: the first prompt grants the scope for later tasks.
	asked := decide(s, true)
	if !request(t, s, "t1", "file_write") || !<-asked {
		t.Fatal("first file_write should ask and be approved")
	}
	if !request(t, s, "t2", "file_write") {
		t.Fatal("grant should cover task t2")
	}
	grants, _ := s.store.ActiveGrants(time.Now())
	if len(grants) != 1 || grants[0].Scope != "file_write" {
		t.Fatalf("grants = %v", grants)
	}

	// A rejection under "once" grants nothing; terminal never auto-approves.
	asked = decide(s, false)
	if request(t, s, "t1", "terminal") || !<-asked {
		t.Fatal("terminal should ask and be rejected")
	}
	asked = decide(s, true)
	if !request(t, s, "t1", "terminal") || !<-asked {
		t.Fatal("terminal should ask again after a rejection")
	}
}

func TestBeforeActingIsPerTask(t *testing.T) {
	s := newTestServer(t)
	t.Setenv("CROW_APPROVAL_EXECUTOR", "before_acting")
	asked := decide(s, true)
	if !request(t, s, "t1", "codex") || !<-asked {
		t.Fatal("first action should ask")
	}
	if !request(t, s, "t1", "codex") {
		t.Fatal("same task should not ask again")
	}
	asked = decide(s, true)
	if !request(t, s, "t2", "codex") || !<-asked {
		t.Fatal("a new task should ask")
	}
}

func TestApprovalLevel(t *testing.T) {
	s := newTestServer(t)
	t.Setenv("CROW_APPROVAL_LEVEL", "relaxed")
	t.Setenv("CROW_APPROVAL_COMPUTER", "auto")
	asked := decide(s, true)
	if !request(t, s, "t1", "computer") || !<-asked {
		t.Fatal("relaxed should ask the first time")
	}
	if !request(t, s, "t2", "computer") {
		t.Fatal("relaxed grant should cover a later task")
	}
	// "codex" is the old executor scope name; cautious asks every time.
	t.Setenv("CROW_APPROVAL_LEVEL", "cautious")
	for i := 0; i < 2; i++ {
		asked = decide(s, true)
		if !request(t, s, "t1", "codex") || !<-asked {
			t.Fatal("cautious should ask every time")
		}
	}
}
