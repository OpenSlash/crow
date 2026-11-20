package llm

import (
	"net/http"
	"testing"
)

func TestParseScutilProxy(t *testing.T) {
	out := []byte("<dictionary> {\n  HTTPEnable : 1\n  HTTPPort : 7890\n  HTTPProxy : 127.0.0.1\n  HTTPSEnable : 1\n  HTTPSPort : 7891\n  HTTPSProxy : proxy.local\n  SOCKSEnable : 0\n}\n")
	p := parseScutilProxy(out)
	if p.http.String() != "http://127.0.0.1:7890" || p.https.String() != "http://proxy.local:7891" {
		t.Fatalf("proxy = %v %v", p.http, p.https)
	}
	if p := parseScutilProxy([]byte("  HTTPSEnable : 0\n  HTTPSProxy : x\n")); p.https != nil || p.http != nil {
		t.Fatalf("disabled proxy = %+v", p)
	}
}

func TestLoopbackNeverProxied(t *testing.T) {
	t.Setenv("HTTPS_PROXY", "http://proxy.example:1")
	t.Setenv("HTTP_PROXY", "http://proxy.example:1")
	for _, raw := range []string{"http://127.0.0.1:11434/v1", "http://localhost:8080"} {
		req, _ := http.NewRequest(http.MethodGet, raw, nil)
		if u, _ := proxyFor(req); u != nil {
			t.Errorf("%s proxied via %v", raw, u)
		}
	}
	req, _ := http.NewRequest(http.MethodGet, "https://api.openai.com/v1", nil)
	if u, _ := proxyFor(req); u == nil || u.Host != "proxy.example:1" {
		t.Errorf("env proxy not used: %v", u)
	}
}
