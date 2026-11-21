package agent

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func runWith(t *testing.T, tool runCommand, command string) string {
	t.Helper()
	args, _ := json.Marshal(map[string]string{"command": command, "reason": "test"})
	res, err := tool.Run(context.Background(), args)
	if err != nil {
		t.Fatal(err)
	}
	return res.Content
}

func TestRunCommandAsksAndRuns(t *testing.T) {
	var asked string
	tool := runCommand{timeout: 10 * time.Second, approve: func(_ context.Context, command, reason string) (bool, error) {
		asked = command + " / " + reason
		return true, nil
	}}
	out := runWith(t, tool, "echo hello; echo oops >&2; exit 3")
	if asked != "echo hello; echo oops >&2; exit 3 / test" {
		t.Fatalf("approval asked with %q", asked)
	}
	if !strings.HasPrefix(out, "Exit code 3\n") || !strings.Contains(out, "hello") || !strings.Contains(out, "oops") {
		t.Fatalf("output = %q", out)
	}
}

func TestRunCommandRejected(t *testing.T) {
	tool := runCommand{timeout: time.Second, approve: func(context.Context, string, string) (bool, error) { return false, nil }}
	if out := runWith(t, tool, "touch /tmp/crow-should-not-exist"); !strings.Contains(out, "rejected") {
		t.Fatalf("output = %q", out)
	}
}

func TestRunCommandRefusesSudoWithoutAsking(t *testing.T) {
	tool := runCommand{timeout: time.Second, approve: func(context.Context, string, string) (bool, error) {
		t.Fatal("must not ask for sudo")
		return false, nil
	}}
	for _, c := range []string{"sudo rm -rf /x", "ls && sudo reboot", "vim notes.txt"} {
		if out := runWith(t, tool, c); !strings.HasPrefix(out, "Not run") {
			t.Fatalf("%q: output = %q", c, out)
		}
	}
}

func TestRunCommandTimeoutKillsGroup(t *testing.T) {
	tool := runCommand{timeout: 2 * time.Second, approve: func(context.Context, string, string) (bool, error) { return true, nil }}
	start := time.Now()
	out := runWith(t, tool, "echo started; sleep 30 | cat")
	if time.Since(start) > 6*time.Second || !strings.Contains(out, "Stopped") || !strings.Contains(out, "started") {
		t.Fatalf("took %v, output = %q", time.Since(start), out)
	}
}

func TestTruncateOutputKeepsHeadAndTail(t *testing.T) {
	s := strings.Repeat("a", commandMaxOutput) + strings.Repeat("z", 100)
	out := truncateOutput(s)
	if !strings.HasPrefix(out, "aaa") || !strings.HasSuffix(out, "zzz") || !strings.Contains(out, "omitted") {
		t.Fatal("unexpected truncation")
	}
}
