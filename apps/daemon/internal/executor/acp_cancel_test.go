package executor

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// fakeACPAgent answers initialize and session/new, starts a long-running child on
// session/prompt, and, when cooperative, ends the prompt on session/cancel.
const fakeACPAgent = `import json, subprocess, sys
cooperative, pidfile = sys.argv[1] == "1", sys.argv[2]
prompt_id = None
def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1}})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "s1"}})
    elif method == "session/prompt":
        prompt_id = msg["id"]
        child = subprocess.Popen(["sleep", "300"])
        open(pidfile, "w").write(str(child.pid))
    elif method == "session/cancel" and cooperative:
        send({"jsonrpc": "2.0", "id": prompt_id, "result": {"stopReason": "cancelled"}})
`

type nopSink struct{}

func (nopSink) ApplyExecutorEvent(context.Context, string, Event) error { return nil }

func TestACPCancel(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 not installed")
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "agent.py")
	if err := os.WriteFile(script, []byte(fakeACPAgent), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CROW_EXECUTOR_CWD", dir)
	old := acpCancelGrace
	acpCancelGrace = 300 * time.Millisecond
	defer func() { acpCancelGrace = old }()

	for name, cooperative := range map[string]string{"cooperative": "1", "unresponsive": "0"} {
		t.Run(name, func(t *testing.T) {
			pidfile := filepath.Join(dir, name+".pid")
			e := NewACPExecutorFromConfig(ExecutorAdapterConfig{
				ID: "fake", Adapter: "acp",
				Command: "exec python3 " + script + " " + cooperative + " " + pidfile,
			})
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan error, 1)
			go func() { done <- e.Run(ctx, Request{TaskID: "t1", Command: "work"}, nopSink{}) }()

			childPID := waitForPID(t, pidfile)
			cancel()
			select {
			case err := <-done:
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("Run = %v, want context.Canceled", err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("Run did not return after cancel")
			}
			// The agent's own children are stopped with it.
			deadline := time.Now().Add(2 * time.Second)
			for syscall.Kill(childPID, 0) == nil {
				if time.Now().After(deadline) {
					_ = syscall.Kill(childPID, syscall.SIGKILL)
					t.Fatalf("child %d still running", childPID)
				}
				time.Sleep(20 * time.Millisecond)
			}
		})
	}
}

func waitForPID(t *testing.T, path string) int {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		if data, err := os.ReadFile(path); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
				return pid
			}
		}
	}
	t.Fatal("fake agent never started its child")
	return 0
}
