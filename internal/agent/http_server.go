package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/Fharena/VibeDeck/internal/protocol"
	"github.com/Fharena/VibeDeck/internal/runtime"
)

type HTTPServer struct {
	adapter        WorkspaceAdapter
	orchestrator   *Orchestrator
	stateManager   *runtime.StateManager
	ackTracker     *runtime.AckTracker
	controlMetrics *ControlMetrics
	controlRouter  *ControlRouter
	p2pManager     *P2PSessionManager
	config         HTTPServerConfig
}

func NewHTTPServer(adapter WorkspaceAdapter, orchestrator *Orchestrator, stateManager *runtime.StateManager, ackTracker *runtime.AckTracker, controlMetrics *ControlMetrics, p2pManager *P2PSessionManager, config HTTPServerConfig) *HTTPServer {
	return &HTTPServer{
		adapter:        adapter,
		orchestrator:   orchestrator,
		stateManager:   stateManager,
		ackTracker:     ackTracker,
		controlMetrics: controlMetrics,
		controlRouter:  NewControlRouter(orchestrator, ackTracker),
		p2pManager:     p2pManager,
		config:         normalizeHTTPServerConfig(config),
	}
}

func (s *HTTPServer) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/metrics", s.handlePrometheusMetrics)
	mux.HandleFunc("/v1/agent/envelope", s.handleEnvelope)
	mux.HandleFunc("/v1/agent/runtime/state", s.handleRuntimeState)
	mux.HandleFunc("/v1/agent/runtime/metrics", s.handleRuntimeMetrics)
	mux.HandleFunc("/v1/agent/runtime/adapter", s.handleRuntimeAdapter)
	mux.HandleFunc("/v1/agent/bootstrap", s.handleBootstrap)
	mux.HandleFunc("/v1/agent/runtime/acks/expired", s.handleExpiredAcks)
	mux.HandleFunc("/v1/agent/runtime/acks/pending", s.handlePendingAcks)
	mux.HandleFunc("/v1/agent/run-profiles", s.handleRunProfiles)
	mux.HandleFunc("/v1/agent/threads", s.handleThreads)
	mux.HandleFunc("/v1/agent/threads/", s.handleThreadDetail)
	mux.HandleFunc("/v1/agent/sessions", s.handleSessions)
	mux.HandleFunc("/v1/agent/sessions/", s.handleSessionPath)
	mux.HandleFunc("/v1/agent/workspace/tree", s.handleWorkspaceTree)
	mux.HandleFunc("/v1/agent/workspace/file", s.handleWorkspaceFile)
	mux.HandleFunc("/v1/agent/p2p/start", s.handleP2PStart)
	mux.HandleFunc("/v1/agent/p2p/status", s.handleP2PStatus)
	mux.HandleFunc("/v1/agent/p2p/stop", s.handleP2PStop)
	return mux
}

func (s *HTTPServer) handleHealth(w http.ResponseWriter, _ *http.Request) {
	p2pActive := false
	if s.p2pManager != nil {
		p2pActive = s.p2pManager.Status().Active
	}

	pendingAcks := 0
	if s.ackTracker != nil {
		pendingAcks = s.ackTracker.PendingCount()
	}

	state := runtime.StatePairing
	if s.stateManager != nil {
		state = s.stateManager.State()
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":      "ok",
		"state":       state,
		"pendingAcks": pendingAcks,
		"p2pActive":   p2pActive,
	})
}

func (s *HTTPServer) handleEnvelope(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	var env protocol.Envelope
	if err := json.NewDecoder(r.Body).Decode(&env); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid envelope json"})
		return
	}

	startedAt := time.Now()
	ctx, cancel := context.WithTimeout(r.Context(), s.config.ControlTimeouts.TimeoutFor(env.Type))
	defer cancel()

	result, err := s.controlRouter.HandleEnvelope(ctx, env)
	if env.Type != protocol.TypeCmdAck && s.controlMetrics != nil {
		s.controlMetrics.Observe(env.Type, ControlPathHTTP, time.Since(startedAt), err)
	}
	if env.Type == protocol.TypeCmdAck {
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid CMD_ACK payload"})
			return
		}

		pendingAcks := 0
		if s.ackTracker != nil {
			pendingAcks = s.ackTracker.PendingCount()
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"handled":     result.AckHandled,
			"requestRid":  result.AckRequestID,
			"pendingAcks": pendingAcks,
		})
		return
	}

	registerAckableResponses(s.ackTracker, result.Responses, runtime.AckTransportHTTP, false)

	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"error":     err.Error(),
			"responses": result.Responses,
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"responses": result.Responses})
}

func (s *HTTPServer) handleRuntimeState(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{
			"state":   s.stateManager.State(),
			"history": s.stateManager.History(),
		})

	case http.MethodPost:
		var req struct {
			Action string `json:"action"`
			Note   string `json:"note,omitempty"`
		}

		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid runtime state request"})
			return
		}

		action := strings.ToLower(strings.TrimSpace(req.Action))
		switch action {
		case "begin_signaling":
			s.stateManager.BeginSignaling()
		case "begin_p2p":
			s.stateManager.BeginP2P()
		case "p2p_connected":
			s.stateManager.MarkP2PConnected()
		case "relay_connected":
			s.stateManager.MarkRelayConnected(req.Note)
		case "reconnecting":
			s.stateManager.BeginReconnect()
		case "close":
			s.stateManager.Close()
		default:
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown action"})
			return
		}

		writeJSON(w, http.StatusOK, map[string]any{
			"state":   s.stateManager.State(),
			"history": s.stateManager.History(),
		})

	default:
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
	}
}

func (s *HTTPServer) handleRuntimeMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	state := runtime.StatePairing
	if s.stateManager != nil {
		state = s.stateManager.State()
	}

	metrics := runtime.EmptyAckMetrics()
	if s.ackTracker != nil {
		metrics = s.ackTracker.Metrics()
	}

	p2pActive := false
	if s.p2pManager != nil {
		p2pActive = s.p2pManager.Status().Active
	}

	control := EmptyControlMetricsSnapshot()
	if s.controlMetrics != nil {
		control = s.controlMetrics.Snapshot()
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"state":     state,
		"p2pActive": p2pActive,
		"ack":       metrics,
		"control":   control,
	})
}

func (s *HTTPServer) handlePrometheusMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	state := runtime.StatePairing
	if s.stateManager != nil {
		state = s.stateManager.State()
	}

	metrics := runtime.EmptyAckMetrics()
	if s.ackTracker != nil {
		metrics = s.ackTracker.Metrics()
	}

	p2pActive := false
	if s.p2pManager != nil {
		p2pActive = s.p2pManager.Status().Active
	}

	control := EmptyControlMetricsSnapshot()
	if s.controlMetrics != nil {
		control = s.controlMetrics.Snapshot()
	}

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(renderPrometheusMetrics(state, p2pActive, metrics, control)))
}

func (s *HTTPServer) handleRuntimeAdapter(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	info := BasicAdapterRuntimeInfo(s.adapter)
	if provider, ok := s.adapter.(AdapterRuntimeInfoProvider); ok {
		info = provider.RuntimeInfo()
	}
	writeJSON(w, http.StatusOK, info)
}

func (s *HTTPServer) handleRunProfiles(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	profiles := []RunProfileDescriptor{}
	if s.orchestrator != nil {
		profiles = s.orchestrator.RunProfiles()
	}
	writeJSON(w, http.StatusOK, map[string]any{"profiles": profiles})
}

func (s *HTTPServer) handleThreads(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	threads := []ThreadSummary{}
	if s.orchestrator != nil && s.orchestrator.ThreadStore() != nil {
		threads = s.orchestrator.ThreadStore().List()
	}
	writeJSON(w, http.StatusOK, map[string]any{"threads": threads})
}

func (s *HTTPServer) handleThreadDetail(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	threadID := strings.TrimPrefix(r.URL.Path, "/v1/agent/threads/")
	threadID = strings.TrimSpace(strings.Trim(threadID, "/"))
	if threadID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "thread id is required"})
		return
	}
	if s.orchestrator == nil || s.orchestrator.ThreadStore() == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "thread not found"})
		return
	}

	detail, ok := s.orchestrator.ThreadStore().Get(threadID)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "thread not found"})
		return
	}
	writeJSON(w, http.StatusOK, detail)
}

func (s *HTTPServer) handleSessions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	sessions := []SharedSessionSummary{}
	if s.orchestrator != nil && s.orchestrator.SessionStore() != nil {
		sessions = s.orchestrator.SessionStore().List()
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": sessions})
}

func (s *HTTPServer) handleSessionDetail(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	sessionID := strings.TrimPrefix(r.URL.Path, "/v1/agent/sessions/")
	sessionID = strings.TrimSpace(strings.Trim(sessionID, "/"))
	if sessionID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "session id is required"})
		return
	}
	if s.orchestrator == nil || s.orchestrator.SessionStore() == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "session not found"})
		return
	}

	detail, ok := s.orchestrator.SessionStore().Get(sessionID)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "session not found"})
		return
	}
	writeJSON(w, http.StatusOK, detail)
}

func (s *HTTPServer) handleExpiredAcks(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	if s.ackTracker == nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"expired": []runtime.PendingAck{},
			"state":   s.stateManager.State(),
		})
		return
	}

	expired := s.ackTracker.Expired()
	if len(expired) > 0 {
		s.stateManager.BeginReconnect()
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"expired": expired,
		"state":   s.stateManager.State(),
	})
}

func (s *HTTPServer) handlePendingAcks(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	if s.ackTracker == nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"pending": []runtime.PendingAck{},
			"count":   0,
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"pending": s.ackTracker.Snapshot(),
		"count":   s.ackTracker.PendingCount(),
	})
}

func (s *HTTPServer) handleP2PStart(w http.ResponseWriter, r *http.Request) {
	if s.p2pManager == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "p2p manager is not configured"})
		return
	}

	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	var req StartP2PRequest
	_ = json.NewDecoder(r.Body).Decode(&req)

	status, err := s.p2pManager.Start(r.Context(), req)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"error":  err.Error(),
			"status": status,
		})
		return
	}

	writeJSON(w, http.StatusOK, status)
}

func (s *HTTPServer) handleP2PStatus(w http.ResponseWriter, r *http.Request) {
	if s.p2pManager == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "p2p manager is not configured"})
		return
	}

	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	writeJSON(w, http.StatusOK, s.p2pManager.Status())
}

func (s *HTTPServer) handleP2PStop(w http.ResponseWriter, r *http.Request) {
	if s.p2pManager == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "p2p manager is not configured"})
		return
	}

	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	status, err := s.p2pManager.Stop()
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{
			"error":  err.Error(),
			"status": status,
		})
		return
	}

	writeJSON(w, http.StatusOK, status)
}

func writeJSON(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}
