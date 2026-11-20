package config

import (
	"os"
	"path/filepath"
	"strings"
)

func LoadDotEnv() {
	for _, path := range dotEnvCandidates() {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		applyDotEnv(string(data))
		return
	}
}

func dotEnvCandidates() []string {
	candidates := []string{}
	if cwd, err := os.Getwd(); err == nil {
		candidates = append(candidates,
			filepath.Join(cwd, ".env"),
			filepath.Join(cwd, "..", ".env"),
			filepath.Join(cwd, "..", "..", ".env"),
			filepath.Join(cwd, "..", "..", "..", ".env"),
		)
	}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(dir, ".env"),
			filepath.Join(dir, "..", ".env"),
			filepath.Join(dir, "..", "..", ".env"),
			filepath.Join(dir, "..", "..", "..", ".env"),
			filepath.Join(dir, "..", "..", "..", "..", ".env"),
		)
	}
	return candidates
}

func applyDotEnv(content string) {
	for _, rawLine := range strings.Split(content, "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		value := stripEnvQuotes(strings.TrimSpace(parts[1]))
		if key == "" || os.Getenv(key) != "" {
			continue
		}
		_ = os.Setenv(key, value)
	}
}

func stripEnvQuotes(value string) string {
	if len(value) >= 2 {
		if (strings.HasPrefix(value, "'") && strings.HasSuffix(value, "'")) || (strings.HasPrefix(value, "\"") && strings.HasSuffix(value, "\"")) {
			return value[1 : len(value)-1]
		}
	}
	return value
}
