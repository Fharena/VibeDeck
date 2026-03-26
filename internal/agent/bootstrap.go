package agent

import (
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

type HTTPServerConfig struct {
	PublicAgentBaseURL         string
	PublicSignalingBaseURL     string
	BootstrapRecentThreadLimit int
	ControlTimeouts            ControlTimeoutConfig
}

type BootstrapResponse struct {
	AgentBaseURL     string                `json:"agentBaseUrl,omitempty"`
	SignalingBaseURL string                `json:"signalingBaseUrl,omitempty"`
	WorkspaceRoot    string                `json:"workspaceRoot,omitempty"`
	Adapter          BootstrapAdapterView  `json:"adapter"`
	ControlTimeouts  ControlTimeoutView    `json:"controlTimeouts"`
	CurrentThreadID  string                `json:"currentThreadId,omitempty"`
	CurrentSessionID string                `json:"currentSessionId,omitempty"`
	RecentThreads    []BootstrapThreadView `json:"recentThreads,omitempty"`
}

type BootstrapAdapterView struct {
	Name     string `json:"name,omitempty"`
	Mode     string `json:"mode,omitempty"`
	Provider string `json:"provider,omitempty"`
	Ready    bool   `json:"ready"`
}

type BootstrapThreadView struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	UpdatedAt int64  `json:"updatedAt"`
	Current   bool   `json:"current"`
}

func normalizeHTTPServerConfig(cfg HTTPServerConfig) HTTPServerConfig {
	cfg.PublicAgentBaseURL = normalizeBaseURL(cfg.PublicAgentBaseURL)
	cfg.PublicSignalingBaseURL = normalizeBaseURL(cfg.PublicSignalingBaseURL)
	if cfg.BootstrapRecentThreadLimit <= 0 {
		cfg.BootstrapRecentThreadLimit = 5
	}
	cfg.ControlTimeouts = normalizeControlTimeoutConfig(cfg.ControlTimeouts)
	return cfg
}

func normalizeBaseURL(value string) string {
	value = strings.TrimSpace(value)
	value = strings.TrimRight(value, "/")
	return value
}

func inferAgentBaseURL(r *http.Request, configured string) string {
	if configured = normalizeBaseURL(configured); configured != "" {
		return configured
	}

	host := strings.TrimSpace(r.Host)
	if host == "" {
		return ""
	}

	scheme := forwardedScheme(r)
	return scheme + "://" + host
}

func resolveBootstrapSignalingBaseURL(r *http.Request, configured string, publicOverride string) string {
	base := normalizeBaseURL(publicOverride)
	if base == "" {
		base = normalizeBaseURL(configured)
	}
	if base == "" {
		return ""
	}

	u, err := url.Parse(base)
	if err != nil {
		return base
	}
	if u.Scheme == "" {
		u.Scheme = forwardedScheme(r)
	}

	requestHost, _ := splitHostPort(strings.TrimSpace(r.Host))
	if requestHost == "" || isLoopbackHost(requestHost) || !isLoopbackHost(u.Hostname()) {
		return u.String()
	}

	if port := u.Port(); port != "" {
		u.Host = net.JoinHostPort(requestHost, port)
	} else {
		u.Host = requestHost
	}
	return u.String()
}

func forwardedScheme(r *http.Request) string {
	if forwarded := strings.TrimSpace(r.Header.Get("X-Forwarded-Proto")); forwarded != "" {
		return forwarded
	}
	if r.TLS != nil {
		return "https"
	}
	return "http"
}

func isLoopbackHost(host string) bool {
	host = strings.TrimSpace(strings.Trim(host, "[]"))
	if host == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func splitHostPort(value string) (string, int) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", 0
	}

	host, portText, err := net.SplitHostPort(value)
	if err == nil {
		port, _ := strconv.Atoi(portText)
		return strings.Trim(host, "[]"), port
	}

	return strings.Trim(value, "[]"), 0
}

func inferProviderName(info AdapterRuntimeInfo) string {
	joined := strings.ToLower(strings.Join([]string{info.Mode, info.Name}, " "))
	switch {
	case strings.Contains(joined, "cursor"):
		return "cursor"
	case strings.Contains(joined, "codex"):
		return "codex"
	case strings.Contains(joined, "claude"):
		return "claude_code"
	case strings.Contains(joined, "antigravity"):
		return "antigravity"
	default:
		return "unknown"
	}
}
