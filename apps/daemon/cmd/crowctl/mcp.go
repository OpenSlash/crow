package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"

	"connectrpc.com/connect"
	crowv1 "github.com/crow/crow/apps/daemon/gen/crow/v1"
	"github.com/crow/crow/apps/daemon/gen/crow/v1/crowv1connect"
	"github.com/crow/crow/apps/daemon/internal/computer"
)

// mcpServer exposes Crow's computer use as an MCP server over stdio, so other
// agents (Claude Code, Codex, ...) can see and operate this Mac through Crow.
// Every action goes through the daemon: the enabled switch, see-only mode and
// approvals apply exactly as for Crow's own tasks.
type mcpServer struct {
	out    io.Writer
	mu     sync.Mutex
	client string
	taskID string
}

type rpcMessage struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
}

const mcpInstructions = "Sees and operates this Mac through the Crow app. Start with action screenshot or elements. " +
	"The user must have enabled computer use in Crow; Crow may ask the user to approve actions. " +
	"Never type passwords, sign in or make payments."

func runMCP(in io.Reader, out io.Writer) error {
	s := &mcpServer{out: out}
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 1<<20), 16<<20)
	for scanner.Scan() {
		var msg rpcMessage
		if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
			s.reply(nil, nil, &rpcError{Code: -32700, Message: "parse error"})
			continue
		}
		if len(msg.ID) == 0 {
			continue // notifications need no reply
		}
		result, rpcErr := s.handle(msg)
		s.reply(msg.ID, result, rpcErr)
	}
	return scanner.Err()
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (s *mcpServer) reply(id json.RawMessage, result any, rpcErr *rpcError) {
	payload := map[string]any{"jsonrpc": "2.0", "id": id}
	if rpcErr != nil {
		payload["error"] = rpcErr
	} else {
		payload["result"] = result
	}
	data, _ := json.Marshal(payload)
	s.mu.Lock()
	defer s.mu.Unlock()
	fmt.Fprintf(s.out, "%s\n", data)
}

func (s *mcpServer) handle(msg rpcMessage) (any, *rpcError) {
	switch msg.Method {
	case "initialize":
		var params struct {
			ProtocolVersion string `json:"protocolVersion"`
			ClientInfo      struct {
				Name string `json:"name"`
			} `json:"clientInfo"`
		}
		_ = json.Unmarshal(msg.Params, &params)
		s.client = params.ClientInfo.Name
		version := params.ProtocolVersion
		if version == "" {
			version = "2025-06-18"
		}
		return map[string]any{
			"protocolVersion": version,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "crow-computer", "version": "0.1.0"},
			"instructions":    mcpInstructions,
		}, nil
	case "ping":
		return map[string]any{}, nil
	case "tools/list":
		spec := computer.ToolSpec(false)
		return map[string]any{"tools": []map[string]any{{
			"name":        spec.Name,
			"description": spec.Description,
			"inputSchema": spec.Parameters,
		}}}, nil
	case "tools/call":
		var params struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(msg.Params, &params); err != nil || params.Name != "computer" {
			return nil, &rpcError{Code: -32602, Message: "unknown tool"}
		}
		return s.callComputer(params.Arguments), nil
	default:
		return nil, &rpcError{Code: -32601, Message: "method not found: " + msg.Method}
	}
}

// callComputer forwards one action to the daemon. Failures are tool errors the
// calling model can read, not protocol errors.
func (s *mcpServer) callComputer(args json.RawMessage) map[string]any {
	toolError := func(err error) map[string]any {
		return map[string]any{"isError": true, "content": []map[string]any{{"type": "text", "text": err.Error()}}}
	}
	// The daemon may have restarted; read its session on every call.
	session, err := readSession()
	if err != nil {
		return toolError(fmt.Errorf("Crow is not running: %w", err))
	}
	client := crowv1connect.NewComputerServiceClient(http.DefaultClient, session.BaseURL)
	res, err := client.Perform(context.Background(), withToken(connect.NewRequest(&crowv1.PerformComputerActionRequest{
		TaskId:   s.taskID,
		ArgsJson: string(args),
		Client:   s.client,
	}), session.Token))
	if err != nil {
		return toolError(fmt.Errorf("%s", connect.CodeOf(err).String()+": "+connectMessage(err)))
	}
	s.taskID = res.Msg.GetTaskId()
	content := []map[string]any{{"type": "text", "text": res.Msg.GetText()}}
	if image := res.Msg.GetImage(); len(image) > 0 {
		content = append(content, map[string]any{
			"type":     "image",
			"data":     base64.StdEncoding.EncodeToString(image),
			"mimeType": res.Msg.GetImageMediaType(),
		})
	}
	return map[string]any{"content": content}
}

func connectMessage(err error) string {
	if connectErr, ok := err.(*connect.Error); ok {
		return connectErr.Message()
	}
	return err.Error()
}

func mcpMain() {
	if err := runMCP(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "crowctl mcp:", err)
		os.Exit(1)
	}
}
