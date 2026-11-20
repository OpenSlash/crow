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

type recordingSink struct{ events []Event }

func (s *recordingSink) ApplyExecutorEvent(_ context.Context, _ string, ev Event) error {
	s.events = append(s.events, ev)
	return nil
}

func TestACPStreamedReplyIsNotFragmented(t *testing.T) {
	e := &ACPExecutor{id: "codex", name: "Codex"}
	sink := &recordingSink{}
	var transcript acpTranscript
	for _, chunk := range []string{"下载", "目录", "：", "202", "6", "-", "11", "|", "a.jpg"} {
		e.handleACPUpdate(context.Background(), "t1", sink, map[string]any{
			"sessionUpdate": "agent_message_chunk",
			"content":       map[string]any{"type": "text", "text": chunk},
		}, &transcript)
	}
	if transcript.text.String() != "下载目录：2026-11|a.jpg" {
		t.Fatalf("transcript = %q", transcript.text.String())
	}
	for _, ev := range sink.events {
		if ev.Type == "voice.output.segment" {
			t.Fatalf("voice segment emitted: %+v", ev)
		}
	}
	if len(sink.events) != 1 || sink.events[0].Type != "executor.output" {
		t.Fatalf("events = %d %+v", len(sink.events), sink.events)
	}
}

func TestACPAnswerFollowsLastToolCall(t *testing.T) {
	e := &ACPExecutor{id: "codex", name: "Codex"}
	sink := &recordingSink{}
	var tr acpTranscript
	send := func(update map[string]any) { e.handleACPUpdate(context.Background(), "t1", sink, update, &tr) }
	chunk := func(text string) map[string]any {
		return map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": text}}
	}
	send(chunk("我先看看目录。"))
	send(map[string]any{"sessionUpdate": "tool_call", "title": "List files", "kind": "read"})
	send(chunk("目录可读取。"))
	send(map[string]any{"sessionUpdate": "tool_call", "title": "Read metadata", "kind": "read"})
	send(chunk("最近的文件是 a.jpg。"))
	if got := tr.answer(); got != "最近的文件是 a.jpg。" {
		t.Fatalf("answer = %q", got)
	}
	for i := 0; i < 50; i++ {
		send(map[string]any{"sessionUpdate": "agent_thought_chunk", "content": map[string]any{"type": "text", "text": "想"}})
	}
	thoughts := 0
	for _, ev := range sink.events {
		if ev.Type == "executor.thought" {
			thoughts++
		}
	}
	if thoughts != 1 {
		t.Fatalf("thought events = %d", thoughts)
	}
	var none acpTranscript
	none.text.WriteString("直接回答。")
	if none.answer() != "直接回答。" {
		t.Fatalf("no-tool answer = %q", none.answer())
	}
}

func TestACPChunksKeepWhitespace(t *testing.T) {
	e := &ACPExecutor{id: "codex", name: "Codex"}
	var tr acpTranscript
	for _, chunk := range []string{"1. a.txt", " - ", "2026-11-20", " 10:48", "\n", "2. b.jpg"} {
		e.handleACPUpdate(context.Background(), "t1", &recordingSink{}, map[string]any{
			"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": chunk},
		}, &tr)
	}
	if got := tr.answer(); got != "1. a.txt - 2026-11-20 10:48\n2. b.jpg" {
		t.Fatalf("answer = %q", got)
	}
}
