// Package llm talks to model providers directly with the user's own API key.
package llm

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type Message struct {
	Role       string // "user", "assistant" or "tool"
	Content    string
	ToolCalls  []ToolCall // assistant messages that call tools
	ToolCallID string     // tool messages: the call this result answers
	Images     []Image    // tool messages: images returned by the tool, e.g. screenshots
}

// Image is an encoded picture, e.g. a JPEG screenshot.
type Image struct {
	MediaType string // "image/jpeg" or "image/png"
	Data      []byte
}

func (i Image) base64() string { return base64.StdEncoding.EncodeToString(i.Data) }

// Tool is a function the model may call. Parameters is a JSON Schema object.
type Tool struct {
	Name        string
	Description string
	Parameters  map[string]any
}

type ToolCall struct {
	ID        string
	Name      string
	Arguments string // JSON object
}

type Request struct {
	System      string
	Messages    []Message
	Tools       []Tool
	MaxTokens   int
	Temperature float64
}

type Response struct {
	Text      string
	ToolCalls []ToolCall
	Model     string
	Provider  string
}

// Provider streams a chat completion. onDelta receives text chunks as they arrive.
type Provider interface {
	Name() string
	Model() string
	Stream(ctx context.Context, req Request, onDelta func(string) error) (Response, error)
}

type Config struct {
	Provider string
	BaseURL  string
	APIKey   string
	Model    string
}

type preset struct {
	baseURL   string
	model     string
	anthropic bool
	keyless   bool
}

// OpenAI-compatible unless anthropic is set.
var presets = map[string]preset{
	"openai":     {baseURL: "https://api.openai.com/v1", model: "gpt-4.1-mini"},
	"anthropic":  {baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-5-5", anthropic: true},
	"deepseek":   {baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"},
	"moonshot":   {baseURL: "https://api.moonshot.cn/v1"},
	"qwen":       {baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"},
	"glm":        {baseURL: "https://open.bigmodel.cn/api/paas/v4"},
	"openrouter": {baseURL: "https://openrouter.ai/api/v1"},
	"ollama":     {baseURL: "http://127.0.0.1:11434/v1", keyless: true},
	"custom":     {},
}

var ErrNotConfigured = errors.New("model provider is not configured")

// ConfigFromEnv reads CROW_LLM_* and falls back to the legacy CROW_OPENAI_* variables.
func ConfigFromEnv() Config {
	cfg := Config{
		Provider: strings.ToLower(env("CROW_LLM_PROVIDER")),
		BaseURL:  env("CROW_LLM_BASE_URL"),
		APIKey:   env("CROW_LLM_API_KEY"),
		Model:    env("CROW_LLM_MODEL"),
	}
	if cfg.Provider == "" {
		cfg.Provider = "openai"
	}
	if cfg.Provider == "openai" {
		if cfg.APIKey == "" {
			cfg.APIKey = env("CROW_OPENAI_API_KEY")
		}
		if cfg.BaseURL == "" {
			cfg.BaseURL = env("CROW_OPENAI_BASE_URL")
		}
		if cfg.Model == "" {
			cfg.Model = env("CROW_OPENAI_AGENT_MODEL")
		}
	}
	return cfg
}

func New(cfg Config) (Provider, error) {
	p, ok := presets[cfg.Provider]
	if !ok {
		return nil, fmt.Errorf("unknown model provider %q", cfg.Provider)
	}
	baseURL := normalizeBaseURL(firstNonEmpty(cfg.BaseURL, p.baseURL))
	model := firstNonEmpty(cfg.Model, p.model)
	switch {
	case baseURL == "":
		return nil, fmt.Errorf("%w: CROW_LLM_BASE_URL is required for %s", ErrNotConfigured, cfg.Provider)
	case model == "":
		return nil, fmt.Errorf("%w: CROW_LLM_MODEL is required for %s", ErrNotConfigured, cfg.Provider)
	case cfg.APIKey == "" && !p.keyless:
		return nil, fmt.Errorf("%w: CROW_LLM_API_KEY is required for %s", ErrNotConfigured, cfg.Provider)
	}
	base := client{name: cfg.Provider, baseURL: baseURL, apiKey: cfg.APIKey, model: model, http: httpClient()}
	if p.anthropic {
		return &anthropicProvider{base}, nil
	}
	return &openAIProvider{base}, nil
}

type client struct {
	name    string
	baseURL string
	apiKey  string
	model   string
	http    *http.Client
}

func (c client) Name() string  { return c.name }
func (c client) Model() string { return c.model }

// normalizeBaseURL appends /v1 to a bare host such as https://api.openai.com.
func normalizeBaseURL(raw string) string {
	raw = strings.TrimRight(strings.TrimSpace(raw), "/")
	if raw == "" {
		return ""
	}
	if u, err := url.Parse(raw); err == nil && (u.Path == "" || u.Path == "/") {
		return raw + "/v1"
	}
	return raw
}

func httpClient() *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = proxyFor
	// CROW_LLM_DISABLE_PROXY, not crow-cloud's CROW_OPENAI_DISABLE_PROXY: that one
	// is a server-side escape hatch and must not change how the daemon connects.
	if strings.EqualFold(env("CROW_LLM_DISABLE_PROXY"), "true") {
		transport.Proxy = nil
	}
	// No overall timeout: streams can be long. Requests are bounded by ctx.
	transport.ResponseHeaderTimeout = 60 * time.Second
	return &http.Client{Transport: transport}
}

func env(key string) string { return strings.TrimSpace(os.Getenv(key)) }

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v = strings.TrimSpace(v); v != "" {
			return v
		}
	}
	return ""
}
