package server

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/textproto"
	"os"
	"strings"
	"time"
)

type OpenAITranscriptionResult struct {
	Text string `json:"text"`
}

type OpenAISpeechResult struct {
	Audio       []byte
	ContentType string
}

func (a *API) transcribeWithOpenAI(ctx context.Context, audio []byte, filename string, contentType string, language string) (OpenAITranscriptionResult, error) {
	if strings.TrimSpace(a.cfg.OpenAIAPIKey) == "" {
		return OpenAITranscriptionResult{}, fmt.Errorf("OpenAI API key is not configured")
	}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	_ = writer.WriteField("model", firstNonEmptyString(a.cfg.OpenAISTTModel, "gpt-4o-mini-transcribe"))
	if strings.TrimSpace(language) != "" {
		_ = writer.WriteField("language", strings.TrimSpace(language))
	}
	_ = writer.WriteField("response_format", "json")

	if filename == "" {
		filename = "crow-audio.wav"
	}
	if contentType == "" {
		contentType = "audio/wav"
	}
	header := make(textproto.MIMEHeader)
	header.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename="%s"`, escapeMultipartFilename(filename)))
	header.Set("Content-Type", contentType)
	part, err := writer.CreatePart(header)
	if err != nil {
		return OpenAITranscriptionResult{}, err
	}
	if _, err := part.Write(audio); err != nil {
		return OpenAITranscriptionResult{}, err
	}
	if err := writer.Close(); err != nil {
		return OpenAITranscriptionResult{}, err
	}

	url := strings.TrimRight(firstNonEmptyString(a.cfg.OpenAIBaseURL, "https://api.openai.com"), "/") + "/v1/audio/transcriptions"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, &body)
	if err != nil {
		return OpenAITranscriptionResult{}, err
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(a.cfg.OpenAIAPIKey))
	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := voiceHTTPClient().Do(req)
	if err != nil {
		return OpenAITranscriptionResult{}, err
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return OpenAITranscriptionResult{}, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return OpenAITranscriptionResult{}, fmt.Errorf("OpenAI transcription failed with status %d: %s", resp.StatusCode, compactErrorBody(data))
	}

	var result OpenAITranscriptionResult
	if err := json.Unmarshal(data, &result); err != nil {
		return OpenAITranscriptionResult{}, err
	}
	return result, nil
}

func (a *API) speakWithOpenAI(ctx context.Context, text string, voice string, format string) (OpenAISpeechResult, error) {
	if strings.TrimSpace(a.cfg.OpenAIAPIKey) == "" {
		return OpenAISpeechResult{}, fmt.Errorf("OpenAI API key is not configured")
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return OpenAISpeechResult{}, fmt.Errorf("text is required")
	}
	if voice == "" {
		voice = firstNonEmptyString(a.cfg.OpenAITTSVoice, "marin")
	}
	if format == "" {
		format = "mp3"
	}

	payload, err := json.Marshal(map[string]interface{}{
		"model":           firstNonEmptyString(a.cfg.OpenAITTSModel, "gpt-4o-mini-tts"),
		"voice":           voice,
		"input":           text,
		"response_format": format,
	})
	if err != nil {
		return OpenAISpeechResult{}, err
	}

	url := strings.TrimRight(firstNonEmptyString(a.cfg.OpenAIBaseURL, "https://api.openai.com"), "/") + "/v1/audio/speech"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return OpenAISpeechResult{}, err
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(a.cfg.OpenAIAPIKey))
	req.Header.Set("Content-Type", "application/json")

	resp, err := voiceHTTPClient().Do(req)
	if err != nil {
		return OpenAISpeechResult{}, err
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return OpenAISpeechResult{}, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return OpenAISpeechResult{}, fmt.Errorf("OpenAI speech failed with status %d: %s", resp.StatusCode, compactErrorBody(data))
	}

	contentType := resp.Header.Get("Content-Type")
	if contentType == "" {
		contentType = contentTypeForSpeechFormat(format)
	}
	return OpenAISpeechResult{Audio: data, ContentType: contentType}, nil
}

func (a *API) streamSpeechWithOpenAI(ctx context.Context, text string, voice string, writer io.Writer) error {
	if strings.TrimSpace(a.cfg.OpenAIAPIKey) == "" {
		return fmt.Errorf("OpenAI API key is not configured")
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return fmt.Errorf("text is required")
	}
	if voice == "" {
		voice = firstNonEmptyString(a.cfg.OpenAITTSVoice, "marin")
	}

	payload, err := json.Marshal(map[string]interface{}{
		"model":           firstNonEmptyString(a.cfg.OpenAITTSModel, "gpt-4o-mini-tts"),
		"voice":           voice,
		"input":           text,
		"response_format": "pcm",
		"stream_format":   "audio",
	})
	if err != nil {
		return err
	}

	url := strings.TrimRight(firstNonEmptyString(a.cfg.OpenAIBaseURL, "https://api.openai.com"), "/") + "/v1/audio/speech"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(a.cfg.OpenAIAPIKey))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "audio/pcm")

	resp, err := voiceHTTPClient().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		return fmt.Errorf("OpenAI speech stream failed with status %d: %s", resp.StatusCode, compactErrorBody(data))
	}

	_, err = io.Copy(writer, resp.Body)
	return err
}

func voiceHTTPClient() *http.Client {
	resolveIP := strings.TrimSpace(os.Getenv("CROW_OPENAI_RESOLVE_IP"))
	disableProxy := boolEnvString(os.Getenv("CROW_OPENAI_DISABLE_PROXY")) || resolveIP != ""
	if resolveIP == "" && !disableProxy {
		return &http.Client{Timeout: 90 * time.Second}
	}

	dialer := &net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if disableProxy {
		transport.Proxy = nil
	}
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	transport.DialContext = func(ctx context.Context, network string, address string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(address)
		if err != nil {
			return nil, err
		}
		if resolveIP != "" && strings.EqualFold(host, "api.openai.com") {
			address = net.JoinHostPort(resolveIP, port)
		}
		return dialer.DialContext(ctx, network, address)
	}
	return &http.Client{Timeout: 90 * time.Second, Transport: transport}
}

func boolEnvString(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func escapeMultipartFilename(filename string) string {
	return strings.NewReplacer("\\", "\\\\", `"`, "\\\"").Replace(filename)
}

func compactErrorBody(data []byte) string {
	text := strings.TrimSpace(string(data))
	if len(text) > 600 {
		return text[:600]
	}
	return text
}

func contentTypeForSpeechFormat(format string) string {
	switch strings.ToLower(strings.TrimSpace(format)) {
	case "wav":
		return "audio/wav"
	case "opus":
		return "audio/opus"
	case "aac":
		return "audio/aac"
	case "flac":
		return "audio/flac"
	case "pcm":
		return "audio/pcm"
	default:
		return "audio/mpeg"
	}
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
