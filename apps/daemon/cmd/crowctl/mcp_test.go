package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestMCPHandshakeAndTools(t *testing.T) {
	t.Setenv("HOME", t.TempDir()) // no daemon session
	in := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"test"}}}`,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"computer","arguments":{"action":"screenshot"}}}`,
		`{"jsonrpc":"2.0","id":4,"method":"nope"}`,
	}, "\n")
	var out bytes.Buffer
	if err := runMCP(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 4 {
		t.Fatalf("replies = %d:\n%s", len(lines), out.String())
	}
	var replies []map[string]any
	for _, line := range lines {
		var r map[string]any
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			t.Fatal(err)
		}
		replies = append(replies, r)
	}
	if v := replies[0]["result"].(map[string]any)["protocolVersion"]; v != "2025-06-18" {
		t.Fatalf("initialize = %v", replies[0])
	}
	tools := replies[1]["result"].(map[string]any)["tools"].([]any)
	if tools[0].(map[string]any)["name"] != "computer" {
		t.Fatalf("tools = %v", tools)
	}
	call := replies[2]["result"].(map[string]any)
	if call["isError"] != true || !strings.Contains(lines[2], "Crow is not running") {
		t.Fatalf("call = %v", call)
	}
	if replies[3]["error"].(map[string]any)["code"].(float64) != -32601 {
		t.Fatalf("unknown method = %v", replies[3])
	}
}
