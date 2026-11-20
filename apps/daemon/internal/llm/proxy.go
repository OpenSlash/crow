package llm

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// proxyFor uses HTTP(S)_PROXY from the environment, else the macOS system proxy
// (System Settings → Network → Proxies, which tools like Clash set). Go's
// default transport only reads the environment. Loopback hosts never use a proxy.
func proxyFor(req *http.Request) (*url.URL, error) {
	if isLoopback(req.URL.Hostname()) {
		return nil, nil
	}
	if u, err := http.ProxyFromEnvironment(req); u != nil || err != nil {
		return u, err
	}
	p := currentSystemProxy()
	if req.URL.Scheme == "https" {
		return p.https, nil
	}
	return p.http, nil
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

type systemProxy struct{ http, https *url.URL }

var (
	proxyMu      sync.Mutex
	proxyCache   systemProxy
	proxyFetched time.Time
)

// currentSystemProxy re-reads the system proxy at most every 30 s, so switching
// a proxy tool on or off takes effect without restarting the daemon.
func currentSystemProxy() systemProxy {
	proxyMu.Lock()
	defer proxyMu.Unlock()
	if time.Since(proxyFetched) < 30*time.Second {
		return proxyCache
	}
	proxyFetched = time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/sbin/scutil", "--proxy").Output()
	if err != nil {
		proxyCache = systemProxy{}
		return proxyCache
	}
	proxyCache = parseScutilProxy(out)
	return proxyCache
}

// parseScutilProxy reads the HTTP and HTTPS entries of `scutil --proxy`.
func parseScutilProxy(out []byte) systemProxy {
	values := map[string]string{}
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		key, value, ok := strings.Cut(scanner.Text(), " : ")
		if ok {
			values[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	entry := func(prefix string) *url.URL {
		if values[prefix+"Enable"] != "1" || values[prefix+"Proxy"] == "" {
			return nil
		}
		host := values[prefix+"Proxy"]
		if port := values[prefix+"Port"]; port != "" {
			host = net.JoinHostPort(host, port)
		}
		return &url.URL{Scheme: "http", Host: host}
	}
	return systemProxy{http: entry("HTTP"), https: entry("HTTPS")}
}
