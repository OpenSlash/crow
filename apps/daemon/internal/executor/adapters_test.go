package executor

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadExternalCommandExecutors(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CROW_EXECUTOR_DIR", dir)
	t.Setenv("CROW_EXECUTOR_DIRS", "")
	t.Setenv("CROW_EXECUTOR_DISABLE_DEFAULT_DIRS", "true")
	t.Setenv("CROW_EXECUTOR_CWD", "")

	config := `{
		"id": "openclaw",
		"name": "OpenClaw",
		"description": "Browser and research executor.",
		"adapter": "command",
		"enabled": true,
		"kinds": ["browser", "research"],
		"command": "printf '%s\n' '{\"type\":\"task.completed\",\"title\":\"Done\",\"message\":\"ok\"}'",
		"supportsStreaming": true,
		"supportsApproval": false
	}`
	if err := os.WriteFile(filepath.Join(dir, "openclaw.json"), []byte(config), 0o644); err != nil {
		t.Fatal(err)
	}

	executors, warnings := LoadExternalCommandExecutors()
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	if len(executors) != 1 {
		t.Fatalf("expected one executor, got %d", len(executors))
	}
	if executors[0].ID() != "openclaw" {
		t.Fatalf("expected openclaw executor, got %s", executors[0].ID())
	}
	if !executors[0].EnabledFor("browser") || executors[0].EnabledFor("email") {
		t.Fatalf("executor kind routing mismatch")
	}
}

func TestLoadExecutorAdapterConfigDefaults(t *testing.T) {
	path := filepath.Join(t.TempDir(), "adapter.json")
	if err := os.WriteFile(path, []byte(`{"id":" My Adapter ","command":"echo ok"}`), 0o644); err != nil {
		t.Fatal(err)
	}

	config, err := LoadExecutorAdapterConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if config.ID != "my-adapter" {
		t.Fatalf("expected normalized id, got %q", config.ID)
	}
	if config.Adapter != "command" {
		t.Fatalf("expected command adapter, got %q", config.Adapter)
	}
	if len(config.Kinds) != 1 || config.Kinds[0] != "agent" {
		t.Fatalf("expected default agent kind, got %v", config.Kinds)
	}
	if config.Name != "my-adapter" {
		t.Fatalf("expected default name from id, got %q", config.Name)
	}
}

func TestLoadCodexAdapterConfigIsUnsupported(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CROW_EXECUTOR_DIR", dir)
	t.Setenv("CROW_EXECUTOR_DIRS", "")
	t.Setenv("CROW_EXECUTOR_DISABLE_DEFAULT_DIRS", "true")
	t.Setenv("CROW_EXECUTOR_CWD", "")

	config := `{
		"id": "codex",
		"name": "Codex",
		"adapter": "codex",
		"enabled": true,
		"kinds": ["code", "agent"],
		"command": "/usr/local/bin/codex",
		"supportsStreaming": true,
		"supportsApproval": true
	}`
	if err := os.WriteFile(filepath.Join(dir, "codex.json"), []byte(config), 0o644); err != nil {
		t.Fatal(err)
	}

	executors, configs, warnings := LoadExecutorAdapters()
	if len(configs) != 1 || configs[0].Adapter != "codex" {
		t.Fatalf("expected codex config, got %#v", configs)
	}
	if len(warnings) == 0 {
		t.Fatalf("expected unsupported adapter warning")
	}
	if len(executors) != 0 {
		t.Fatalf("expected no executor for legacy codex adapter, got %d", len(executors))
	}
}

func TestLoadACPAdapterConfig(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CROW_EXECUTOR_DIR", dir)
	t.Setenv("CROW_EXECUTOR_DIRS", "")
	t.Setenv("CROW_EXECUTOR_DISABLE_DEFAULT_DIRS", "true")
	t.Setenv("CROW_EXECUTOR_CWD", "")

	config := `{
		"id": "claude-code",
		"name": "Claude Code",
		"adapter": "acp",
		"enabled": true,
		"kinds": ["code", "agent"],
		"command": "claude acp",
		"supportsStreaming": true,
		"supportsApproval": true
	}`
	if err := os.WriteFile(filepath.Join(dir, "claude-code.json"), []byte(config), 0o644); err != nil {
		t.Fatal(err)
	}

	executors, configs, warnings := LoadExecutorAdapters()
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	if len(configs) != 1 || configs[0].Adapter != "acp" {
		t.Fatalf("expected acp config, got %#v", configs)
	}
	if len(executors) != 1 {
		t.Fatalf("expected one executor, got %d", len(executors))
	}
	descriptor, ok := executors[0].(DescribedExecutor)
	if !ok {
		t.Fatalf("expected described executor")
	}
	if descriptor.Descriptor().Adapter != "acp" {
		t.Fatalf("expected acp descriptor, got %s", descriptor.Descriptor().Adapter)
	}
	if !executors[0].EnabledFor("code") || !executors[0].EnabledFor("agent") || executors[0].EnabledFor("email") {
		t.Fatalf("acp executor kind routing mismatch")
	}
}

func TestBuildConfiguredExecutorsDoesNotAutoRegisterCodeExecutor(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("CROW_EXECUTOR_DIR", dir)
	t.Setenv("CROW_EXECUTOR_DIRS", "")
	t.Setenv("CROW_EXECUTOR_DISABLE_DEFAULT_DIRS", "true")
	t.Setenv("CROW_EXECUTOR_CWD", "")
	t.Setenv("CROW_AGENT_COMMAND", "")
	t.Setenv("CROW_HERMES_COMMAND", "")
	t.Setenv("CROW_MAIL_COMMAND", "")

	executors, warnings := BuildConfiguredExecutors()
	if len(warnings) != 0 {
		t.Fatalf("expected no warnings, got %v", warnings)
	}
	if len(executors) != 0 {
		t.Fatalf("expected no configured executors, got %d", len(executors))
	}
}
