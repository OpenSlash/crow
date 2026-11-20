package executor

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type ExecutorAdapterConfig struct {
	ID                string            `json:"id"`
	Name              string            `json:"name"`
	Description       string            `json:"description"`
	Version           string            `json:"version,omitempty"`
	Publisher         string            `json:"publisher,omitempty"`
	Homepage          string            `json:"homepage,omitempty"`
	Adapter           string            `json:"adapter"`
	Command           string            `json:"command"`
	Kinds             []string          `json:"kinds"`
	Enabled           *bool             `json:"enabled,omitempty"`
	Env               map[string]string `json:"env,omitempty"`
	SupportsStreaming bool              `json:"supportsStreaming"`
	SupportsApproval  bool              `json:"supportsApproval"`
	Source            string            `json:"-"`
}

func BuildConfiguredExecutors() ([]Executor, []string) {
	executors, configs, warnings := LoadExecutorAdapters()
	configIDs := map[string]bool{}
	for _, config := range configs {
		configIDs[config.ID] = true
	}

	if command := strings.TrimSpace(os.Getenv("CROW_AGENT_COMMAND")); command != "" && !configIDs["agent-command"] {
		executors = append(executors, NewCommandExecutor("agent-command", command, "code", "agent"))
	}
	if command := strings.TrimSpace(os.Getenv("CROW_HERMES_COMMAND")); command != "" && !configIDs["hermes"] {
		executors = append(executors, NewCommandExecutor("hermes", command, "browser", "research", "general"))
	}
	if command := strings.TrimSpace(os.Getenv("CROW_MAIL_COMMAND")); command != "" && !configIDs["mail"] {
		executors = append(executors, NewCommandExecutor("mail", command, "email"))
	}

	return executors, warnings
}

func LoadExternalCommandExecutors() ([]Executor, []string) {
	executors, _, warnings := LoadExecutorAdapters()
	return executors, warnings
}

func LoadExecutorAdapters() ([]Executor, []ExecutorAdapterConfig, []string) {
	configs, warnings := LoadExecutorAdapterConfigs()
	executors := []Executor{}
	for _, config := range configs {
		adapter := strings.ToLower(strings.TrimSpace(config.Adapter))
		if adapter != "" && adapter != "command" && adapter != "acp" {
			warnings = append(warnings, fmt.Sprintf("Adapter %s skipped: unsupported adapter type %q", config.ID, config.Adapter))
			continue
		}
		enabled := true
		if config.Enabled != nil {
			enabled = *config.Enabled
		}
		if !enabled {
			continue
		}
		if adapter == "acp" {
			if strings.TrimSpace(config.Command) == "" {
				warnings = append(warnings, fmt.Sprintf("Adapter %s skipped: command is empty", config.ID))
				continue
			}
			executors = append(executors, NewACPExecutorFromConfig(config))
			continue
		}
		if strings.TrimSpace(config.Command) == "" {
			warnings = append(warnings, fmt.Sprintf("Adapter %s skipped: command is empty", config.ID))
			continue
		}
		executors = append(executors, NewCommandExecutorFromConfig(config))
	}
	return executors, configs, warnings
}

func LoadExecutorAdapterConfigs() ([]ExecutorAdapterConfig, []string) {
	configsByID := map[string]ExecutorAdapterConfig{}
	warnings := []string{}
	for _, dir := range ExecutorAdapterDirs() {
		entries, err := os.ReadDir(dir)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			warnings = append(warnings, fmt.Sprintf("Read executor dir %s failed: %v", dir, err))
			continue
		}
		for _, entry := range entries {
			if entry.IsDir() || !strings.HasSuffix(strings.ToLower(entry.Name()), ".json") {
				continue
			}
			path := filepath.Join(dir, entry.Name())
			config, err := LoadExecutorAdapterConfig(path)
			if err != nil {
				warnings = append(warnings, err.Error())
				continue
			}
			if config.ID == "" {
				warnings = append(warnings, fmt.Sprintf("Adapter config %s skipped: id is empty", path))
				continue
			}
			configsByID[config.ID] = config
		}
	}

	ids := []string{}
	for id := range configsByID {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	configs := []ExecutorAdapterConfig{}
	for _, id := range ids {
		configs = append(configs, configsByID[id])
	}
	return configs, warnings
}

func LoadExecutorAdapterConfig(path string) (ExecutorAdapterConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return ExecutorAdapterConfig{}, fmt.Errorf("Read executor adapter %s failed: %w", path, err)
	}
	var config ExecutorAdapterConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return ExecutorAdapterConfig{}, fmt.Errorf("Parse executor adapter %s failed: %w", path, err)
	}
	config.ID = normalizeAdapterID(config.ID)
	config.Name = strings.TrimSpace(config.Name)
	config.Description = strings.TrimSpace(config.Description)
	config.Version = strings.TrimSpace(config.Version)
	config.Publisher = strings.TrimSpace(config.Publisher)
	config.Homepage = strings.TrimSpace(config.Homepage)
	config.Adapter = firstNonEmpty(strings.ToLower(strings.TrimSpace(config.Adapter)), "command")
	config.Command = strings.TrimSpace(config.Command)
	config.Kinds = normalizeAdapterKinds(config.Kinds)
	config.Source = path
	if config.Env == nil {
		config.Env = map[string]string{}
	}
	if config.Name == "" {
		config.Name = config.ID
	}
	if config.Description == "" {
		config.Description = "External command executor."
	}
	if len(config.Kinds) == 0 {
		config.Kinds = []string{"agent"}
	}
	return config, nil
}

func ExecutorAdapterDirs() []string {
	dirs := []string{}
	if value := strings.TrimSpace(os.Getenv("CROW_EXECUTOR_DIRS")); value != "" {
		for _, dir := range filepath.SplitList(value) {
			dirs = append(dirs, dir)
		}
	}
	if value := strings.TrimSpace(os.Getenv("CROW_EXECUTOR_DIR")); value != "" {
		dirs = append(dirs, value)
	}
	if boolEnv("CROW_EXECUTOR_DISABLE_DEFAULT_DIRS", false) {
		return uniqueCleanPaths(dirs)
	}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, ".crow", "executors"))
	}
	for _, root := range candidateExecutorRoots() {
		dirs = append(dirs, filepath.Join(root, ".crow", "executors"))
	}
	return uniqueCleanPaths(dirs)
}

func candidateExecutorRoots() []string {
	roots := []string{}
	if cwd := strings.TrimSpace(os.Getenv("CROW_EXECUTOR_CWD")); cwd != "" {
		roots = append(roots, cwd)
	}
	if cwd, err := os.Getwd(); err == nil {
		roots = append(roots, cwd)
	}
	return uniqueCleanPaths(roots)
}

func normalizeAdapterID(id string) string {
	id = strings.ToLower(strings.TrimSpace(id))
	id = strings.ReplaceAll(id, " ", "-")
	return strings.Trim(id, ".-_")
}

func normalizeAdapterKinds(kinds []string) []string {
	seen := map[string]bool{}
	result := []string{}
	for _, kind := range kinds {
		kind = strings.ToLower(strings.TrimSpace(kind))
		if kind == "" || seen[kind] {
			continue
		}
		seen[kind] = true
		result = append(result, kind)
	}
	return result
}

func uniqueCleanPaths(paths []string) []string {
	seen := map[string]bool{}
	result := []string{}
	for _, path := range paths {
		path = expandHome(strings.TrimSpace(os.ExpandEnv(path)))
		if path == "" {
			continue
		}
		cleaned := filepath.Clean(path)
		if seen[cleaned] {
			continue
		}
		seen[cleaned] = true
		result = append(result, cleaned)
	}
	return result
}

func expandHome(path string) string {
	if path == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			return home
		}
	}
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, path[2:])
		}
	}
	return path
}

func boolEnv(key string, fallback bool) bool {
	value := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if value == "" {
		return fallback
	}
	return value == "1" || value == "true" || value == "yes" || value == "on"
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
