package llm

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// postSSE sends a JSON body and calls onData for every SSE "data:" payload.
func (c client) postSSE(ctx context.Context, url string, headers map[string]string, body any, onData func([]byte) error) error {
	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		return fmt.Errorf("%s request failed with status %d: %s", c.name, resp.StatusCode, compactError(data))
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64<<10), 4<<20)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "[DONE]" {
			break
		}
		if err := onData([]byte(data)); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func compactError(data []byte) string {
	var decoded struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
		Message string `json:"message"`
	}
	if json.Unmarshal(data, &decoded) == nil {
		if msg := firstNonEmpty(decoded.Error.Message, decoded.Message); msg != "" {
			return msg
		}
	}
	text := strings.TrimSpace(string(data))
	if len(text) > 300 {
		text = text[:300] + "…"
	}
	return text
}
