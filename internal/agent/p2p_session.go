package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/Fharena/VibeDeck/internal/protocol"
	"github.com/Fharena/VibeDeck/internal/runtime"
	"github.com/Fharena/VibeDeck/internal/webrtc"
	"github.com/gorilla/websocket"
)

type StartP2PRequest struct {
	SignalingBaseURL string `json:"signalingBaseUrl,omitempty"`
}

type P2PSessionStatus struct {
	Active           bool                    `json:"active"`
	SessionID        string                  `json:"sessionId,omitempty"`
	PairingCode      string                  `json:"pairingCode,omitempty"`
	ExpiresAt        int64                   `json:"expiresAt,omitempty"`
	SignalingBaseURL string                  `json:"signalingBaseUrl,omitempty"`
	State            runtime.ConnectionState `json:"state"`
	LastError        string                  `json:"lastError,omitempty"`
	UpdatedAt        int64                   `json:"updatedAt"`
}

type pairingCreateResponse struct {
	Code        string `json:"code"`
	SessionID   string `json:"sessionId"`
	PCDeviceKey string `json:"pcDeviceKey"`
	ExpiresAt   int64  `json:"expiresAt"`
}

type p2pRuntime struct {
	sessionID   string
	pairingCode string
	expiresAt   int64
	wsURL       string

	peer   *webrtc.Peer
	bridge *webrtc.SignalBridge
	wsConn *websocket.Conn

	wsWriteMu sync.Mutex
	cancel    context.CancelFunc
}

type P2PSessionManager struct {
	stateManager    *runtime.StateManager
	ackTracker      *runtime.AckTracker
	controlMetrics  *ControlMetrics
	controlRouter   *ControlRouter
	controlTimeouts ControlTimeoutConfig
	httpClient      *http.Client

	defaultSignalingBaseURL string

	mu      sync.RWMutex
	active  *p2pRuntime
	status  P2PSessionStatus
	started bool
}

func NewP2PSessionManager(stateManager *runtime.StateManager, ackTracker *runtime.AckTracker, orchestrator *Orchestrator, signalingBaseURL string) *P2PSessionManager {
	if strings.TrimSpace(signalingBaseURL) == "" {
		signalingBaseURL = "http://127.0.0.1:8081"
	}

	return &P2PSessionManager{
		stateManager:    stateManager,
		ackTracker:      ackTracker,
		controlRouter:   NewControlRouter(orchestrator, ackTracker),
		controlTimeouts: DefaultControlTimeoutConfig(),
		httpClient: &http.Client{
			Timeout: 6 * time.Second,
		},
		defaultSignalingBaseURL: signalingBaseURL,
		status: P2PSessionStatus{
			Active:    false,
			State:     stateManager.State(),
			UpdatedAt: time.Now().UTC().UnixMilli(),
		},
	}
}

func (m *P2PSessionManager) SetControlMetrics(metrics *ControlMetrics) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.controlMetrics = metrics
}

func (m *P2PSessionManager) SetControlTimeouts(cfg ControlTimeoutConfig) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.controlTimeouts = normalizeControlTimeoutConfig(cfg)
}

func (m *P2PSessionManager) DefaultSignalingBaseURL() string {
	return strings.TrimSpace(m.defaultSignalingBaseURL)
}

func (m *P2PSessionManager) Start(ctx context.Context, req StartP2PRequest) (P2PSessionStatus, error) {
	m.mu.Lock()
	if m.active != nil {
		defer m.mu.Unlock()
		return m.statusLocked(), errors.New("p2p session already active")
	}
	m.mu.Unlock()

	baseURL := strings.TrimSpace(req.SignalingBaseURL)
	if baseURL == "" {
		baseURL = m.defaultSignalingBaseURL
	}

	pairing, err := m.createPairing(ctx, baseURL)
	if err != nil {
		m.setLastError(fmt.Sprintf("create pairing failed: %v", err))
		return m.Status(), err
	}

	wsURL, err := buildSessionWSURL(baseURL, pairing.SessionID, pairing.PCDeviceKey, "pc")
	if err != nil {
		m.setLastError(fmt.Sprintf("build ws url failed: %v", err))
		return m.Status(), err
	}

	wsConn, _, err := websocket.DefaultDialer.DialContext(ctx, wsURL, nil)
	if err != nil {
		m.setLastError(fmt.Sprintf("dial signaling ws failed: %v", err))
		return m.Status(), err
	}

	peer, err := webrtc.NewPeer(webrtc.DefaultConfig(webrtc.SidePC))
	if err != nil {
		_ = wsConn.Close()
		m.setLastError(fmt.Sprintf("new pc peer failed: %v", err))
		return m.Status(), err
	}

	bridge, err := webrtc.NewSignalBridge(pairing.SessionID, webrtc.SidePC, peer)
	if err != nil {
		_ = peer.Close()
		_ = wsConn.Close()
		m.setLastError(fmt.Sprintf("new signal bridge failed: %v", err))
		return m.Status(), err
	}

	sessionCtx, cancel := context.WithCancel(context.Background())
	rt := &p2pRuntime{
		sessionID:   pairing.SessionID,
		pairingCode: pairing.Code,
		expiresAt:   pairing.ExpiresAt,
		wsURL:       wsURL,
		peer:        peer,
		bridge:      bridge,
		wsConn:      wsConn,
		cancel:      cancel,
	}

	m.mu.Lock()
	m.active = rt
	m.started = true
	m.status = P2PSessionStatus{
		Active:           true,
		SessionID:        pairing.SessionID,
		PairingCode:      pairing.Code,
		ExpiresAt:        pairing.ExpiresAt,
		SignalingBaseURL: baseURL,
		State:            m.stateManager.State(),
		UpdatedAt:        time.Now().UTC().UnixMilli(),
	}
	m.mu.Unlock()

	m.stateManager.BeginSignaling()
	m.updateStateSnapshot()

	go bridge.Run(sessionCtx)
	go m.wsReadLoop(sessionCtx, rt)
	go m.wsWriteLoop(sessionCtx, rt)
	go m.bridgeErrorLoop(sessionCtx, rt)
	go m.peerStateLoop(sessionCtx, rt)
	go m.peerMessageLoop(sessionCtx, rt)
	go m.ackRetryLoop(sessionCtx, rt)

	return m.Status(), nil
}

func (m *P2PSessionManager) Stop() (P2PSessionStatus, error) {
	m.mu.Lock()
	rt := m.active
	if rt == nil {
		status := m.statusLocked()
		m.mu.Unlock()
		return status, errors.New("p2p session is not active")
	}
	m.active = nil
	m.mu.Unlock()

	rt.cancel()

	if m.ackTracker != nil {
		m.ackTracker.ForgetBySessionTransport(rt.sessionID, runtime.AckTransportP2P)
	}

	rt.wsWriteMu.Lock()
	_ = rt.wsConn.Close()
	rt.wsWriteMu.Unlock()

	_ = rt.peer.Close()

	m.stateManager.Close()
	m.updateStateSnapshot()

	m.mu.Lock()
	m.status.Active = false
	m.status.SessionID = ""
	m.status.PairingCode = ""
	m.status.ExpiresAt = 0
	m.status.UpdatedAt = time.Now().UTC().UnixMilli()
	status := m.statusLocked()
	m.mu.Unlock()

	return status, nil
}

func (m *P2PSessionManager) Status() P2PSessionStatus {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.started {
		m.status.State = m.stateManager.State()
		m.status.UpdatedAt = time.Now().UTC().UnixMilli()
	}

	return m.statusLocked()
}

func (m *P2PSessionManager) statusLocked() P2PSessionStatus {
	return m.status
}

func (m *P2PSessionManager) setLastError(message string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.status.LastError = message
	m.status.State = m.stateManager.State()
	m.status.UpdatedAt = time.Now().UTC().UnixMilli()
}

func (m *P2PSessionManager) updateStateSnapshot() {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.status.State = m.stateManager.State()
	m.status.UpdatedAt = time.Now().UTC().UnixMilli()
}

func (m *P2PSessionManager) createPairing(ctx context.Context, signalingBaseURL string) (pairingCreateResponse, error) {
	u, err := buildPairingURL(signalingBaseURL)
	if err != nil {
		return pairingCreateResponse{}, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, nil)
	if err != nil {
		return pairingCreateResponse{}, fmt.Errorf("new pairing request: %w", err)
	}

	resp, err := m.httpClient.Do(req)
	if err != nil {
		return pairingCreateResponse{}, fmt.Errorf("pairing request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		return pairingCreateResponse{}, fmt.Errorf("pairing request unexpected status: %d", resp.StatusCode)
	}

	var out pairingCreateResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return pairingCreateResponse{}, fmt.Errorf("decode pairing response: %w", err)
	}

	if out.Code == "" || out.SessionID == "" || out.PCDeviceKey == "" {
		return pairingCreateResponse{}, errors.New("invalid pairing response")
	}

	return out, nil
}

func (m *P2PSessionManager) wsReadLoop(ctx context.Context, rt *p2pRuntime) {
	for {
		if ctx.Err() != nil {
			return
		}

		var env protocol.Envelope
		if err := rt.wsConn.ReadJSON(&env); err != nil {
			if ctx.Err() != nil {
				return
			}
			m.setLastError(fmt.Sprintf("signaling ws read failed: %v", err))
			m.stateManager.BeginReconnect()
			m.updateStateSnapshot()
			return
		}

		if err := env.Validate(); err != nil {
			continue
		}

		if err := rt.bridge.InboundEnvelope(env); err != nil {
			m.setLastError(fmt.Sprintf("bridge inbound failed: %v", err))
		}
	}
}

func (m *P2PSessionManager) wsWriteLoop(ctx context.Context, rt *p2pRuntime) {
	for {
		select {
		case env := <-rt.bridge.Outbound():
			if env.Type == protocol.TypeSignalOffer {
				m.stateManager.BeginP2P()
				m.updateStateSnapshot()
			}

			rt.wsWriteMu.Lock()
			err := rt.wsConn.WriteJSON(env)
			rt.wsWriteMu.Unlock()
			if err != nil {
				if ctx.Err() != nil {
					return
				}
				m.setLastError(fmt.Sprintf("signaling ws write failed: %v", err))
				m.stateManager.BeginReconnect()
				m.updateStateSnapshot()
				return
			}

		case <-ctx.Done():
			return
		}
	}
}

func (m *P2PSessionManager) bridgeErrorLoop(ctx context.Context, rt *p2pRuntime) {
	for {
		select {
		case err := <-rt.bridge.Errors():
			if err == nil {
				continue
			}
			m.setLastError(fmt.Sprintf("bridge runtime error: %v", err))
			m.stateManager.BeginReconnect()
			m.updateStateSnapshot()

		case <-ctx.Done():
			return
		}
	}
}

func (m *P2PSessionManager) peerStateLoop(ctx context.Context, rt *p2pRuntime) {
	for {
		select {
		case state := <-rt.peer.States():
			switch state {
			case webrtc.StateConnected:
				m.stateManager.MarkP2PConnected()
				m.updateStateSnapshot()

			case webrtc.StateDisconnected, webrtc.StateFailed:
				m.stateManager.BeginReconnect()
				m.updateStateSnapshot()
			}

		case <-ctx.Done():
			return
		}
	}
}

func (m *P2PSessionManager) peerMessageLoop(ctx context.Context, rt *p2pRuntime) {
	for {
		select {
		case message := <-rt.peer.Messages():
			var env protocol.Envelope
			if err := json.Unmarshal(message, &env); err != nil {
				m.setLastError(fmt.Sprintf("decode control envelope failed: %v", err))
				continue
			}

			if err := env.Validate(); err != nil {
				m.setLastError(fmt.Sprintf("invalid control envelope: %v", err))
				continue
			}

			if env.SID != rt.sessionID {
				m.setLastError(fmt.Sprintf("control envelope sid mismatch: expected=%s got=%s", rt.sessionID, env.SID))
				continue
			}

			startedAt := time.Now()
			handleCtx, cancel := context.WithTimeout(ctx, m.controlTimeouts.TimeoutFor(env.Type))
			result, err := m.controlRouter.HandleEnvelope(handleCtx, env)
			cancel()
			if env.Type != protocol.TypeCmdAck && m.controlMetrics != nil {
				m.controlMetrics.Observe(env.Type, ControlPathP2P, time.Since(startedAt), err)
			}
			if err != nil {
				m.setLastError(fmt.Sprintf("control envelope handling failed: %v", err))
			}

			if env.Type == protocol.TypeCmdAck {
				continue
			}

			for _, response := range result.Responses {
				if err := m.sendPeerEnvelope(rt, response); err != nil {
					if ctx.Err() != nil {
						return
					}
					m.setLastError(fmt.Sprintf("send control response failed: %v", err))
					m.stateManager.BeginReconnect()
					m.updateStateSnapshot()
					return
				}
				registerAckableResponses(m.ackTracker, []protocol.Envelope{response}, runtime.AckTransportP2P, true)
			}

		case <-ctx.Done():
			return
		}
	}
}

func (m *P2PSessionManager) ackRetryLoop(ctx context.Context, rt *p2pRuntime) {
	if m.ackTracker == nil {
		return
	}

	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			batch := m.ackTracker.DueRetries()

			for _, exhausted := range batch.Exhausted {
				if exhausted.Transport != runtime.AckTransportP2P || exhausted.SID != rt.sessionID {
					continue
				}
				m.setLastError(fmt.Sprintf(
					"ack retry exhausted: rid=%s type=%s retries=%d",
					exhausted.RID,
					exhausted.MessageType,
					exhausted.RetryCount,
				))
				m.stateManager.BeginReconnect()
				m.updateStateSnapshot()
			}

			for _, retry := range batch.Retries {
				if retry.Pending.Transport != runtime.AckTransportP2P || retry.Pending.SID != rt.sessionID {
					continue
				}
				if err := m.sendPeerEnvelope(rt, retry.Envelope); err != nil {
					if ctx.Err() != nil {
						return
					}
					m.setLastError(fmt.Sprintf(
						"ack retry send failed: rid=%s attempt=%d err=%v",
						retry.Pending.RID,
						retry.Pending.RetryCount,
						err,
					))
					m.stateManager.BeginReconnect()
					m.updateStateSnapshot()
					return
				}
			}

		case <-ctx.Done():
			return
		}
	}
}

func (m *P2PSessionManager) sendPeerEnvelope(rt *p2pRuntime, env protocol.Envelope) error {
	data, err := json.Marshal(env)
	if err != nil {
		return fmt.Errorf("marshal envelope: %w", err)
	}

	if err := rt.peer.Send(data); err != nil {
		return fmt.Errorf("peer send: %w", err)
	}

	return nil
}

func buildPairingURL(signalingBaseURL string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(signalingBaseURL))
	if err != nil {
		return "", fmt.Errorf("parse signaling base url: %w", err)
	}
	if u.Scheme == "" {
		u.Scheme = "http"
	}

	u.Path = strings.TrimRight(u.Path, "/") + "/v1/pairings"
	u.RawQuery = ""
	return u.String(), nil
}

func buildSessionWSURL(signalingBaseURL, sessionID, deviceKey, role string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(signalingBaseURL))
	if err != nil {
		return "", fmt.Errorf("parse signaling base url: %w", err)
	}

	switch u.Scheme {
	case "http":
		u.Scheme = "ws"
	case "https":
		u.Scheme = "wss"
	case "ws", "wss":
	default:
		return "", fmt.Errorf("unsupported signaling base scheme: %s", u.Scheme)
	}

	u.Path = strings.TrimRight(u.Path, "/") + "/v1/sessions/" + sessionID + "/ws"
	q := u.Query()
	q.Set("deviceKey", deviceKey)
	if role != "" {
		q.Set("role", role)
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}
