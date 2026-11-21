package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/crow/crow/apps/daemon/internal/llm"
)

// CommandApprover asks the user whether a command may run. reason says, in the
// user's language, why the command is needed.
type CommandApprover func(ctx context.Context, command, reason string) (bool, error)

// RunCommand lets the model run a short shell command itself and read the output,
// instead of handing a one-line job to Codex. Every command goes through approve.
func RunCommand(approve CommandApprover) Tool {
	return runCommand{approve: approve, timeout: commandTimeout}
}

const (
	commandTimeout   = 60 * time.Second
	commandMaxOutput = 12000 // runes kept from the output, split between head and tail
)

// Commands that need a password or a person at the keyboard cannot run here.
var interactiveCommand = regexp.MustCompile(`(^|[;&|(]\s*)(sudo|su|passwd|login|ssh|vim?|nano|less|more|top)(\s|$)`)

type runCommand struct {
	approve CommandApprover
	timeout time.Duration
}

func (runCommand) Spec() llm.Tool {
	return llm.Tool{
		Name: "run_command",
		Description: "Run a short shell command (zsh) on this Mac and read its output, e.g. disk space (df -h), folder sizes, " +
			"listing or finding files, processes, battery, network or system information. The user approves each command. " +
			"Prefer read-only commands; change or delete things only when the user asked for exactly that. " +
			"No sudo, passwords or interactive programs. For coding or multi-step work on files and repositories, use delegate_to_codex.",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"command": map[string]any{"type": "string", "description": "The command line. It runs in the home folder and must finish within 60 seconds."},
				"reason":  map[string]any{"type": "string", "description": "Why, in a few words in the user's language; shown when asking for approval."},
			},
			"required": []string{"command"},
		},
	}
}

func (runCommand) Activity() Activity {
	return Activity{Kind: ActivityRunning, Label: "Running command"}
}

func (runCommand) PromptNote() string {
	return "To answer questions about this Mac that a shell command can answer (disk, files, processes, system information), " +
		"call run_command yourself and answer from its output; do not open the Terminal app."
}

func (t runCommand) Run(ctx context.Context, args json.RawMessage) (ToolResult, error) {
	var in struct {
		Command string `json:"command"`
		Reason  string `json:"reason"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return ToolResult{}, fmt.Errorf("invalid arguments: %w", err)
	}
	command := strings.TrimSpace(in.Command)
	if command == "" {
		return ToolResult{}, errors.New("command is required")
	}
	if interactiveCommand.MatchString(command) {
		return ToolResult{Content: "Not run: commands that need sudo, a password or an interactive terminal cannot run here. Tell the user to run it in Terminal themselves."}, nil
	}
	approved, err := t.approve(ctx, command, strings.TrimSpace(in.Reason))
	if err != nil {
		return ToolResult{}, err
	}
	if !approved {
		return ToolResult{Content: "The user rejected this command. Do not run it again; ask what they would like instead."}, nil
	}
	return ToolResult{Content: t.exec(ctx, command)}, nil
}

func (t runCommand) exec(ctx context.Context, command string) string {
	ctx, cancel := context.WithTimeout(ctx, t.timeout)
	defer cancel()
	// -f skips the user's startup files, whose messages would mix into the output;
	// commandPath adds the usual tool folders the app's environment lacks.
	cmd := exec.Command("/bin/zsh", "-fc", command)
	home, _ := os.UserHomeDir()
	cmd.Dir = home
	cmd.Env = append(os.Environ(), "PATH="+commandPath(home), "TERM=dumb", "NO_COLOR=1")
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return "Could not start the command: " + err.Error()
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var waitErr error
	select {
	case waitErr = <-done:
	case <-ctx.Done():
		// Kill the whole process group, including pipelines and children.
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		return truncateOutput(out.String()) + "\n[Stopped: the command did not finish within " + t.timeout.String() + ".]"
	}
	code := 0
	var exitErr *exec.ExitError
	if errors.As(waitErr, &exitErr) {
		code = exitErr.ExitCode()
	} else if waitErr != nil {
		return "The command failed: " + waitErr.Error()
	}
	output := truncateOutput(out.String())
	if strings.TrimSpace(output) == "" {
		output = "(no output)"
	}
	return fmt.Sprintf("Exit code %d\n%s", code, output)
}

func commandPath(home string) string {
	dirs := []string{"/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"}
	if home != "" {
		dirs = append(dirs, home+"/.local/bin", home+"/go/bin")
	}
	dirs = append(dirs, strings.Split(os.Getenv("PATH"), ":")...)
	dirs = append(dirs, "/usr/bin", "/bin", "/usr/sbin", "/sbin")
	seen := map[string]bool{}
	var path []string
	for _, d := range dirs {
		if d != "" && !seen[d] {
			seen[d] = true
			path = append(path, d)
		}
	}
	return strings.Join(path, ":")
}

func truncateOutput(s string) string {
	s = strings.ToValidUTF8(s, "�")
	if utf8.RuneCountInString(s) <= commandMaxOutput {
		return s
	}
	r := []rune(s)
	half := commandMaxOutput / 2
	return string(r[:half]) + fmt.Sprintf("\n[… %d characters omitted …]\n", len(r)-commandMaxOutput) + string(r[len(r)-half:])
}
