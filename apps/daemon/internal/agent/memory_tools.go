package agent

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/crow/crow/apps/daemon/internal/llm"
	"github.com/crow/crow/apps/daemon/internal/memory"
)

const memoryPrompt = `You have long-term memory stored as Markdown files: PROFILE.md (who the user is, preferences), topics/<topic>.md (notes on a subject) and journal/YYYY-MM-DD.md ("journal" means today).
When the user shares a lasting fact or preference, or asks you to remember something, save it with memory_write; keep PROFILE.md short and replace stale facts instead of piling up.
Use memory_search or memory_read when past context would help. Never store passwords, API keys or other secrets.`

// MemoryTools returns the memory_search, memory_read and memory_write tools.
func MemoryTools(store *memory.Store) []Tool {
	return []Tool{memorySearch{store}, memoryRead{store}, memoryWrite{store}}
}

func memoryPromptSection(store *memory.Store) string {
	section := "\n\n" + memoryPrompt
	if profile := store.Profile(); profile != "" {
		section += "\n\n<profile>\n" + profile + "\n</profile>"
	}
	return section
}

func pathParam(description string) map[string]any {
	return map[string]any{"type": "string", "description": description}
}

type memorySearch struct{ store *memory.Store }

func (memorySearch) Spec() llm.Tool {
	return llm.Tool{
		Name:        "memory_search",
		Description: "Search long-term memory for lines containing any of the query words.",
		Parameters: map[string]any{
			"type":       "object",
			"properties": map[string]any{"query": pathParam("Keywords, in the language the memory was written in.")},
			"required":   []string{"query"},
		},
	}
}

func (memorySearch) Activity() Activity {
	return Activity{Kind: ActivitySearching, Label: "Searching memory"}
}

func (t memorySearch) Run(_ context.Context, args json.RawMessage) (ToolResult, error) {
	var in struct {
		Query string `json:"query"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return ToolResult{}, fmt.Errorf("invalid arguments: %w", err)
	}
	out, err := t.store.Search(in.Query)
	return ToolResult{Content: out}, err
}

type memoryRead struct{ store *memory.Store }

func (memoryRead) Spec() llm.Tool {
	return llm.Tool{
		Name:        "memory_read",
		Description: "Read a memory file. Omit path to list all files.",
		Parameters: map[string]any{
			"type":       "object",
			"properties": map[string]any{"path": pathParam(`PROFILE.md, topics/<topic>.md, journal/YYYY-MM-DD.md or "journal" for today.`)},
		},
	}
}

func (memoryRead) Activity() Activity {
	return Activity{Kind: ActivityReading, Label: "Recalling"}
}

func (t memoryRead) Run(_ context.Context, args json.RawMessage) (ToolResult, error) {
	var in struct {
		Path string `json:"path"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return ToolResult{}, fmt.Errorf("invalid arguments: %w", err)
	}
	out, err := t.store.Read(in.Path)
	return ToolResult{Content: out}, err
}

type memoryWrite struct{ store *memory.Store }

func (memoryWrite) Spec() llm.Tool {
	return llm.Tool{
		Name:        "memory_write",
		Description: "Save to long-term memory. Appends by default; set replace to rewrite the whole file (read it first).",
		Parameters: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"path":    pathParam(`PROFILE.md, topics/<topic>.md or "journal" for today.`),
				"content": pathParam("Markdown to save."),
				"replace": map[string]any{"type": "boolean", "description": "Rewrite the file instead of appending."},
			},
			"required": []string{"path", "content"},
		},
	}
}

func (memoryWrite) Activity() Activity {
	return Activity{Kind: ActivityWriting, Label: "Saving to memory"}
}

func (t memoryWrite) Run(_ context.Context, args json.RawMessage) (ToolResult, error) {
	var in struct {
		Path    string `json:"path"`
		Content string `json:"content"`
		Replace bool   `json:"replace"`
	}
	if err := json.Unmarshal(args, &in); err != nil {
		return ToolResult{}, fmt.Errorf("invalid arguments: %w", err)
	}
	rel, err := t.store.Write(in.Path, in.Content, in.Replace)
	if err != nil {
		return ToolResult{}, err
	}
	return ToolResult{Content: "Saved to " + rel}, nil
}
