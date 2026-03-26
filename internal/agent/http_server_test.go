package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Fharena/VibeDeck/internal/protocol"
	"github.com/Fharena/VibeDeck/internal/runtime"
)

func newTestHTTPServer() (*HTTPServer, *runtime.AckTracker, *ControlMetrics) {
	adapter := NewMockAdapter()
	threadStore := NewThreadStore()
	orch := NewOrchestrator(adapter, DefaultRunProfiles(), threadStore)
	stateManager := runtime.NewStateManager(runtime.DefaultManagerConfig())
	ackTracker := runtime.NewAckTracker(2 * time.Second)
	controlMetrics := NewControlMetrics()
	p2pManager := NewP2PSessionManager(stateManager, ackTracker, orch, "http://127.0.0.1:8081")
	p2pManager.SetControlMetrics(controlMetrics)

	server := NewHTTPServer(
		adapter,
		orch,
		stateManager,
		ackTracker,
		controlMetrics,
		p2pManager,
		HTTPServerConfig{},
	)

	return server, ackTracker, controlMetrics
}

func TestHTTPServerHandleEnvelope(t *testing.T) {
	server, _, _ := newTestHTTPServer()

	body := []byte(`{"sid":"sid-1","rid":"rid-1","seq":1,"ts":1700000000000,"type":"PROMPT_SUBMIT","payload":{"prompt":"Fix auth","contextOptions":{}}}`)

	req := httptest.NewRequest(http.MethodPost, "/v1/agent/envelope", bytes.NewReader(body))
	rec := httptest.NewRecorder()

	server.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestHTTPServerRuntimeState(t *testing.T) {
	server, _, _ := newTestHTTPServer()

	req := httptest.NewRequest(http.MethodPost, "/v1/agent/runtime/state", bytes.NewBufferString(`{"action":"begin_signaling"}`))
	rec := httptest.NewRecorder()

	server.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestHTTPServerRuntimeMetrics(t *testing.T) {
	server, tracker, controlMetrics := newTestHTTPServer()

	env, err := protocol.NewEnvelope("sid-1", "rid-metrics", 1, protocol.TypePromptAck, map[string]any{
		"jobId": "job_1",
	})
	if err != nil {
		t.Fatalf("build metrics envelope: %v", err)
	}
	tracker.RegisterEnvelope(env, runtime.AckTransportHTTP, false)
	tracker.Ack(env.RID)

	controlMetrics.Observe(protocol.TypePromptSubmit, ControlPathHTTP, 25*time.Millisecond, nil)

	req := httptest.NewRequest(http.MethodGet, "/v1/agent/runtime/metrics", nil)
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var body struct {
		State     runtime.ConnectionState `json:"state"`
		P2PActive bool                    `json:"p2pActive"`
		Ack       runtime.AckMetrics      `json:"ack"`
		Control   ControlMetricsSnapshot  `json:"control"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode runtime metrics: %v", err)
	}

	if body.Ack.AckedCount != 1 {
		t.Fatalf("expected acked count 1, got %d", body.Ack.AckedCount)
	}
	if body.Ack.PendingCount != 0 {
		t.Fatalf("expected pending count 0, got %d", body.Ack.PendingCount)
	}
	if body.Ack.PendingByTransport[string(runtime.AckTransportHTTP)] != 0 {
		t.Fatalf("expected http pending 0")
	}
	if body.Control.Totals.Requests != 1 {
		t.Fatalf("expected control request count 1, got %d", body.Control.Totals.Requests)
	}
	if body.Control.ByPath[ControlPathHTTP].Successes != 1 {
		t.Fatalf("expected http control success count 1, got %+v", body.Control.ByPath[ControlPathHTTP])
	}
	if body.Control.ByType[string(protocol.TypePromptSubmit)].Requests != 1 {
		t.Fatalf("expected prompt_submit control count 1, got %+v", body.Control.ByType)
	}
}

func TestHTTPServerRuntimeAdapter(t *testing.T) {
	server, _, _ := newTestHTTPServer()

	req := httptest.NewRequest(http.MethodGet, "/v1/agent/runtime/adapter", nil)
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var body AdapterRuntimeInfo
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode runtime adapter: %v", err)
	}
	if body.Name != "mock-cursor" {
		t.Fatalf("expected adapter name mock-cursor, got %s", body.Name)
	}
	if !body.Ready {
		t.Fatalf("expected adapter ready")
	}
	if !body.Capabilities.SupportsStructuredPatch {
		t.Fatalf("expected structured patch capability")
	}
}

func TestHTTPServerRuntimeShutdown(t *testing.T) {
	shutdownCalled := make(chan struct{}, 1)
	server, _, _ := newTestHTTPServer()
	server.config.Shutdown = func(_ context.Context) error {
		select {
		case shutdownCalled <- struct{}{}:
		default:
		}
		return nil
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/agent/runtime/shutdown", nil)
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	select {
	case <-shutdownCalled:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("expected shutdown callback to be called")
	}
}

func TestHTTPServerRunProfilesAndThreadsEndpoints(t *testing.T) {
	server, _, _ := newTestHTTPServer()

	profileReq := httptest.NewRequest(http.MethodGet, "/v1/agent/run-profiles", nil)
	profileRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(profileRec, profileReq)

	if profileRec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", profileRec.Code)
	}

	var profileBody struct {
		Profiles []RunProfileDescriptor `json:"profiles"`
	}
	if err := json.Unmarshal(profileRec.Body.Bytes(), &profileBody); err != nil {
		t.Fatalf("decode run profiles: %v", err)
	}
	if len(profileBody.Profiles) == 0 {
		t.Fatalf("expected non-empty run profile list")
	}

	submitReq := httptest.NewRequest(
		http.MethodPost,
		"/v1/agent/envelope",
		bytes.NewBufferString(`{"sid":"sid-threads","rid":"rid-submit","seq":1,"ts":1700000000000,"type":"PROMPT_SUBMIT","payload":{"prompt":"Create hello world file","contextOptions":{}}}`),
	)
	submitRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(submitRec, submitReq)
	if submitRec.Code != http.StatusOK {
		t.Fatalf("submit response should be 200")
	}

	var submitBody struct {
		Responses []protocol.Envelope `json:"responses"`
	}
	if err := json.Unmarshal(submitRec.Body.Bytes(), &submitBody); err != nil {
		t.Fatalf("decode submit response: %v", err)
	}

	var promptAck protocol.PromptAckPayload
	if err := submitBody.Responses[1].DecodePayload(&promptAck); err != nil {
		t.Fatalf("decode prompt ack: %v", err)
	}

	threadsReq := httptest.NewRequest(http.MethodGet, "/v1/agent/threads", nil)
	threadsRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(threadsRec, threadsReq)
	if threadsRec.Code != http.StatusOK {
		t.Fatalf("threads response should be 200")
	}

	var threadsBody struct {
		Threads []ThreadSummary `json:"threads"`
	}
	if err := json.Unmarshal(threadsRec.Body.Bytes(), &threadsBody); err != nil {
		t.Fatalf("decode threads: %v", err)
	}
	if len(threadsBody.Threads) != 1 {
		t.Fatalf("expected 1 thread, got %+v", threadsBody.Threads)
	}
	if threadsBody.Threads[0].ID != promptAck.ThreadID {
		t.Fatalf("expected thread id %s, got %+v", promptAck.ThreadID, threadsBody.Threads[0])
	}

	detailReq := httptest.NewRequest(http.MethodGet, "/v1/agent/threads/"+promptAck.ThreadID, nil)
	detailRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(detailRec, detailReq)
	if detailRec.Code != http.StatusOK {
		t.Fatalf("thread detail response should be 200")
	}

	var detail ThreadDetail
	if err := json.Unmarshal(detailRec.Body.Bytes(), &detail); err != nil {
		t.Fatalf("decode thread detail: %v", err)
	}
	if len(detail.Events) != 3 {
		t.Fatalf("expected 3 events, got %+v", detail.Events)
	}
	if detail.Thread.CurrentJobID == "" {
		t.Fatalf("expected current job id to be set")
	}
	if detail.Events[2].Kind != "patch_ready" {
		t.Fatalf("expected third event to be patch_ready, got %+v", detail.Events[2])
	}
	filesRaw, ok := detail.Events[2].Data["files"].([]any)
	if !ok || len(filesRaw) == 0 {
		t.Fatalf("expected patch_ready event to include files, got %+v", detail.Events[2].Data)
	}
}

func TestHTTPServerInboundCmdAckClearsPending(t *testing.T) {
	server, tracker, _ := newTestHTTPServer()

	submitReq := httptest.NewRequest(
		http.MethodPost,
		"/v1/agent/envelope",
		bytes.NewBufferString(`{"sid":"sid-1","rid":"rid-submit","seq":1,"ts":1700000000000,"type":"PROMPT_SUBMIT","payload":{"prompt":"Fix auth","contextOptions":{}}}`),
	)
	submitRec := httptest.NewRecorder()

	server.Handler().ServeHTTP(submitRec, submitReq)
	if submitRec.Code != http.StatusOK {
		t.Fatalf("submit response should be 200")
	}

	var submitBody struct {
		Responses []protocol.Envelope `json:"responses"`
	}
	if err := json.Unmarshal(submitRec.Body.Bytes(), &submitBody); err != nil {
		t.Fatalf("decode submit response: %v", err)
	}

	if len(submitBody.Responses) < 2 {
		t.Fatalf("expected at least 2 responses")
	}

	targetRID := ""
	for _, response := range submitBody.Responses {
		if response.Type != protocol.TypeCmdAck {
			targetRID = response.RID
			break
		}
	}

	if targetRID == "" {
		t.Fatalf("tracked response rid not found")
	}

	if tracker.PendingCount() == 0 {
		t.Fatalf("pending acks should exist after submit")
	}

	ackEnvelope, err := protocol.NewEnvelope("sid-1", "rid-ack", 2, protocol.TypeCmdAck, protocol.CmdAckPayload{
		RequestRID: targetRID,
		Accepted:   true,
		Message:    "received",
	})
	if err != nil {
		t.Fatalf("build ack envelope: %v", err)
	}

	ackBytes, _ := json.Marshal(ackEnvelope)
	ackReq := httptest.NewRequest(http.MethodPost, "/v1/agent/envelope", bytes.NewReader(ackBytes))
	ackRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(ackRec, ackReq)

	if ackRec.Code != http.StatusOK {
		t.Fatalf("ack response should be 200, got %d", ackRec.Code)
	}

	if tracker.PendingCount() == 0 {
		return
	}

	snapshot := tracker.Snapshot()
	for _, pending := range snapshot {
		if pending.RID == targetRID {
			t.Fatalf("acked rid should be removed from pending")
		}
	}
}

func TestHTTPServerPrometheusMetricsEndpoint(t *testing.T) {
	server, tracker, controlMetrics := newTestHTTPServer()
	server.stateManager.BeginSignaling()

	env, err := protocol.NewEnvelope("sid-1", "rid-prometheus", 1, protocol.TypePromptAck, map[string]any{
		"jobId": "job_1",
	})
	if err != nil {
		t.Fatalf("build prometheus envelope: %v", err)
	}
	tracker.RegisterEnvelope(env, runtime.AckTransportHTTP, false)
	tracker.Ack(env.RID)

	controlMetrics.Observe(protocol.TypePromptSubmit, ControlPathHTTP, 120*time.Millisecond, nil)
	controlMetrics.Observe(protocol.TypePatchApply, ControlPathP2P, 30*time.Millisecond, context.DeadlineExceeded)

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if !strings.HasPrefix(rec.Header().Get("Content-Type"), "text/plain") {
		t.Fatalf("expected prometheus content type, got %q", rec.Header().Get("Content-Type"))
	}

	body := rec.Body.String()
	for _, pattern := range []string{
		`vibedeck_runtime_state{state="SIGNALING"} 1`,
		`vibedeck_ack_acked_total 1`,
		`vibedeck_control_requests_total{type="PROMPT_SUBMIT",path="http",result="success"} 1`,
		`vibedeck_control_requests_total{type="PATCH_APPLY",path="p2p",result="timeout"} 1`,
	} {
		if !strings.Contains(body, pattern) {
			t.Fatalf("expected prometheus output to contain %q\n%s", pattern, body)
		}
	}
}

func TestHTTPServerP2PStatusEndpoint(t *testing.T) {
	server, _, _ := newTestHTTPServer()

	req := httptest.NewRequest(http.MethodGet, "/v1/agent/p2p/status", nil)
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var status P2PSessionStatus
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode p2p status: %v", err)
	}

	if status.Active {
		t.Fatalf("expected p2p status inactive")
	}
}

func TestHTTPServerBootstrapEndpoint(t *testing.T) {
	server, _, _ := newTestHTTPServer()
	server.orchestrator.ThreadStore().EnsureThread("thread-bootstrap-1", "sid-bootstrap-1", "bootstrap thread")

	req := httptest.NewRequest(http.MethodGet, "/v1/agent/bootstrap", nil)
	req.Host = "192.168.0.24:8080"
	rec := httptest.NewRecorder()
	server.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}

	var body BootstrapResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode bootstrap response: %v", err)
	}
	if body.AgentBaseURL != "http://192.168.0.24:8080" {
		t.Fatalf("expected agent base url to follow request host, got %q", body.AgentBaseURL)
	}
	if body.SignalingBaseURL != "http://192.168.0.24:8081" {
		t.Fatalf("expected signaling base url to follow request host, got %q", body.SignalingBaseURL)
	}
	if body.WorkspaceRoot != "" {
		t.Fatalf("expected empty workspace root for mock adapter, got %q", body.WorkspaceRoot)
	}
	if body.Adapter.Name != "mock-cursor" || body.Adapter.Provider != "cursor" || !body.Adapter.Ready {
		t.Fatalf("unexpected bootstrap adapter info: %+v", body.Adapter)
	}
	if body.ControlTimeouts.Default != "5s" ||
		body.ControlTimeouts.PromptSubmit != "5m" ||
		body.ControlTimeouts.PatchApply != "30s" ||
		body.ControlTimeouts.RunProfile != "5m" {
		t.Fatalf("unexpected control timeout view: %+v", body.ControlTimeouts)
	}
	if body.CurrentThreadID != "thread-bootstrap-1" {
		t.Fatalf("expected current thread id thread-bootstrap-1, got %q", body.CurrentThreadID)
	}
	if body.CurrentSessionID != "thread-bootstrap-1" {
		t.Fatalf("expected current session id thread-bootstrap-1, got %q", body.CurrentSessionID)
	}
	if len(body.RecentThreads) != 1 {
		t.Fatalf("expected 1 recent thread, got %+v", body.RecentThreads)
	}
	if !body.RecentThreads[0].Current {
		t.Fatalf("expected first recent thread to be current")
	}
}

func TestHTTPServerSessionsEndpoints(t *testing.T) {
	server, _, _ := newTestHTTPServer()

	submitReq := httptest.NewRequest(
		http.MethodPost,
		"/v1/agent/envelope",
		bytes.NewBufferString(`{"sid":"sid-sessions","rid":"rid-submit","seq":1,"ts":1700000000000,"type":"PROMPT_SUBMIT","payload":{"prompt":"Create hello world file","contextOptions":{}}}`),
	)
	submitRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(submitRec, submitReq)
	if submitRec.Code != http.StatusOK {
		t.Fatalf("submit response should be 200")
	}

	sessionsReq := httptest.NewRequest(http.MethodGet, "/v1/agent/sessions", nil)
	sessionsRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(sessionsRec, sessionsReq)
	if sessionsRec.Code != http.StatusOK {
		t.Fatalf("sessions response should be 200")
	}

	var sessionsBody struct {
		Sessions []SharedSessionSummary `json:"sessions"`
	}
	if err := json.Unmarshal(sessionsRec.Body.Bytes(), &sessionsBody); err != nil {
		t.Fatalf("decode sessions: %v", err)
	}
	if len(sessionsBody.Sessions) != 1 {
		t.Fatalf("expected 1 session, got %+v", sessionsBody.Sessions)
	}
	if sessionsBody.Sessions[0].Phase != "reviewing" {
		t.Fatalf("expected session phase reviewing, got %+v", sessionsBody.Sessions[0])
	}
	if sessionsBody.Sessions[0].ControlSessionID != "sid-sessions" {
		t.Fatalf("expected control session id sid-sessions, got %+v", sessionsBody.Sessions[0])
	}

	detailReq := httptest.NewRequest(http.MethodGet, "/v1/agent/sessions/"+sessionsBody.Sessions[0].ID, nil)
	detailRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(detailRec, detailReq)
	if detailRec.Code != http.StatusOK {
		t.Fatalf("session detail response should be 200")
	}

	var detail SharedSessionDetail
	if err := json.Unmarshal(detailRec.Body.Bytes(), &detail); err != nil {
		t.Fatalf("decode session detail: %v", err)
	}
	if detail.OperationState.Phase != "reviewing" {
		t.Fatalf("expected operation phase reviewing, got %+v", detail.OperationState)
	}
	if detail.OperationState.PatchSummary == "" {
		t.Fatalf("expected patch summary to be populated, got %+v", detail.OperationState)
	}
	if len(detail.OperationState.PatchFiles) == 0 {
		t.Fatalf("expected patch files to be populated, got %+v", detail.OperationState)
	}
	if detail.LiveState.Plan.Summary == "" || len(detail.LiveState.Tools.Activities) == 0 {
		t.Fatalf("expected live plan/tools to be populated, got %+v", detail.LiveState)
	}
	if detail.Session.ControlSessionID != "sid-sessions" {
		t.Fatalf("expected detail control session id sid-sessions, got %+v", detail.Session)
	}
	if len(detail.Timeline) != 3 {
		t.Fatalf("expected timeline length 3, got %+v", detail.Timeline)
	}
}

func TestHTTPServerSessionLiveUpdateEndpoint(t *testing.T) {
	server, _, _ := newTestHTTPServer()
	sessionID := seedSharedSession(t, server, "sid-live-update", "Keep shared draft in sync")

	liveBody := bytes.NewBufferString(`{"participant":{"participantId":"mobile-main","clientType":"mobile","displayName":"Pixel","active":true,"lastSeenAt":1700000000001},"composer":{"draftText":"cursor와 모바일 초안 공유","isTyping":true,"updatedAt":1700000000002},"focus":{"activeFilePath":"mobile/flutter_app/lib/screens/prompt_screen.dart","selection":"PromptScreen","updatedAt":1700000000003},"activity":{"phase":"composing","summary":"모바일에서 프롬프트 작성 중","updatedAt":1700000000004},"reasoning":{"title":"분석 요약","summary":"패치 준비 전 요구사항을 정리하는 중","sourceKind":"manual","updatedAt":1700000000005},"plan":{"summary":"shared session plan","items":[{"id":"sync","label":"동기화","status":"in_progress","detail":"draft 공유 중","updatedAt":1700000000006}],"updatedAt":1700000000006},"tools":{"currentLabel":"파일 검색","currentStatus":"in_progress","activities":[{"kind":"search","label":"파일 검색","status":"in_progress","detail":"prompt_screen.dart 확인 중","at":1700000000007}],"updatedAt":1700000000007},"terminal":{"status":"running","profileId":"test_all","command":"go test ./...","summary":"테스트 실행 중","updatedAt":1700000000008},"workspace":{"rootPath":"C:\\repo\\workspace","activeFilePath":"mobile/flutter_app/lib/screens/prompt_screen.dart","patchFiles":["mobile/flutter_app/lib/screens/prompt_screen.dart"],"changedFiles":["mobile/flutter_app/lib/screens/prompt_screen.dart"],"updatedAt":1700000000009}}`)
	liveReq := httptest.NewRequest(http.MethodPost, "/v1/agent/sessions/"+sessionID+"/live", liveBody)
	liveRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(liveRec, liveReq)

	if liveRec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", liveRec.Code)
	}

	var detail SharedSessionDetail
	if err := json.Unmarshal(liveRec.Body.Bytes(), &detail); err != nil {
		t.Fatalf("decode live update response: %v", err)
	}
	if len(detail.LiveState.Participants) != 1 || detail.LiveState.Participants[0].ParticipantID != "mobile-main" {
		t.Fatalf("expected live participant update, got %+v", detail.LiveState.Participants)
	}
	if detail.LiveState.Composer.DraftText != "cursor와 모바일 초안 공유" || !detail.LiveState.Composer.IsTyping {
		t.Fatalf("expected composer update, got %+v", detail.LiveState.Composer)
	}
	if detail.LiveState.Focus.ActiveFilePath != "mobile/flutter_app/lib/screens/prompt_screen.dart" {
		t.Fatalf("expected focus update, got %+v", detail.LiveState.Focus)
	}
	if detail.LiveState.Activity.Summary != "모바일에서 프롬프트 작성 중" {
		t.Fatalf("expected activity update, got %+v", detail.LiveState.Activity)
	}
	if detail.LiveState.Reasoning.Title != "분석 요약" || detail.LiveState.Plan.Summary != "shared session plan" {
		t.Fatalf("expected reasoning/plan update, got %+v / %+v", detail.LiveState.Reasoning, detail.LiveState.Plan)
	}
	if detail.LiveState.Tools.CurrentLabel != "파일 검색" || detail.LiveState.Terminal.Command != "go test ./..." {
		t.Fatalf("expected tools/terminal update, got %+v / %+v", detail.LiveState.Tools, detail.LiveState.Terminal)
	}
	if detail.LiveState.Workspace.ActiveFilePath != "mobile/flutter_app/lib/screens/prompt_screen.dart" {
		t.Fatalf("expected workspace update, got %+v", detail.LiveState.Workspace)
	}

	clearBody := bytes.NewBufferString(`{"composer":{"draftText":"","isTyping":false,"updatedAt":0},"focus":{"activeFilePath":"","selection":"","patchPath":"","runErrorPath":"","runErrorLine":0,"updatedAt":0},"activity":{"phase":"","summary":"","updatedAt":0},"reasoning":{"title":"","summary":"","sourceKind":"","updatedAt":0},"plan":{"summary":"","items":[],"updatedAt":0},"tools":{"currentLabel":"","currentStatus":"","activities":[],"updatedAt":0},"terminal":{"status":"","profileId":"","label":"","command":"","summary":"","excerpt":"","output":"","updatedAt":0},"workspace":{"rootPath":"","activeFilePath":"","patchFiles":[],"changedFiles":[],"updatedAt":0}}`)
	clearReq := httptest.NewRequest(http.MethodPost, "/v1/agent/sessions/"+sessionID+"/live", clearBody)
	clearRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(clearRec, clearReq)

	if clearRec.Code != http.StatusOK {
		t.Fatalf("expected 200 for clear update, got %d", clearRec.Code)
	}
	var clearedDetail SharedSessionDetail
	if err := json.Unmarshal(clearRec.Body.Bytes(), &clearedDetail); err != nil {
		t.Fatalf("decode cleared live update response: %v", err)
	}
	if clearedDetail.LiveState.Composer.DraftText != "" || clearedDetail.LiveState.Composer.IsTyping {
		t.Fatalf("expected composer override to clear, got %+v", clearedDetail.LiveState.Composer)
	}
	if clearedDetail.LiveState.Focus.ActiveFilePath != "" || clearedDetail.LiveState.Focus.Selection != "" {
		t.Fatalf("expected focus override to clear, got %+v", clearedDetail.LiveState.Focus)
	}
	if clearedDetail.LiveState.Activity.Phase != "" || clearedDetail.LiveState.Activity.Summary != "" {
		t.Fatalf("expected activity override to clear, got %+v", clearedDetail.LiveState.Activity)
	}
	if clearedDetail.LiveState.Reasoning.Summary != "" || len(clearedDetail.LiveState.Plan.Items) != 0 {
		t.Fatalf("expected reasoning/plan override to clear, got %+v / %+v", clearedDetail.LiveState.Reasoning, clearedDetail.LiveState.Plan)
	}
	if clearedDetail.LiveState.Tools.CurrentLabel != "" || clearedDetail.LiveState.Terminal.Command != "" {
		t.Fatalf("expected tools/terminal override to clear, got %+v / %+v", clearedDetail.LiveState.Tools, clearedDetail.LiveState.Terminal)
	}
	if clearedDetail.LiveState.Workspace.ActiveFilePath != "" || clearedDetail.LiveState.Workspace.RootPath != "" {
		t.Fatalf("expected workspace override to clear, got %+v", clearedDetail.LiveState.Workspace)
	}
}

func TestHTTPServerSessionTimelineAppendEndpoint(t *testing.T) {
	server, _, _ := newTestHTTPServer()
	sessionID := seedSharedSession(t, server, "sid-timeline-append", "Mirror Cursor native chat")

	appendBody := bytes.NewBufferString(`{"events":[{"id":"cursor-bubble:composer-1:bubble-user-1","kind":"provider_message","role":"user","title":"Cursor 사용자 메시지","body":"fix auth middleware","data":{"source":"cursor_storage","composerId":"composer-1","bubbleId":"bubble-user-1"},"at":1700000000100},{"id":"cursor-context:composer-1:bubble-user-1","kind":"tool_activity","title":"Cursor 요청 맥락","body":"files: internal/agent/session_store.go","data":{"source":"cursor_storage","composerId":"composer-1","bubbleId":"bubble-user-1","files":["internal/agent/session_store.go"]},"at":1700000000101}]}`)
	appendReq := httptest.NewRequest(http.MethodPost, "/v1/agent/sessions/"+sessionID+"/events", appendBody)
	appendRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(appendRec, appendReq)

	if appendRec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", appendRec.Code)
	}

	var detail SharedSessionDetail
	if err := json.Unmarshal(appendRec.Body.Bytes(), &detail); err != nil {
		t.Fatalf("decode append response: %v", err)
	}
	if len(detail.Timeline) != 5 {
		t.Fatalf("expected timeline length 5 after append, got %+v", detail.Timeline)
	}
	last := detail.Timeline[len(detail.Timeline)-1]
	if last.Kind != "tool_activity" || last.Role != "system" {
		t.Fatalf("expected default system role tool activity, got %+v", last)
	}
	previous := detail.Timeline[len(detail.Timeline)-2]
	if previous.Kind != "provider_message" || previous.Role != "user" {
		t.Fatalf("expected provider message append, got %+v", previous)
	}

	repeatReq := httptest.NewRequest(
		http.MethodPost,
		"/v1/agent/sessions/"+sessionID+"/events",
		bytes.NewBufferString(`{"events":[{"id":"cursor-bubble:composer-1:bubble-user-1","kind":"provider_message","role":"user","title":"Cursor 사용자 메시지","body":"fix auth middleware","at":1700000000100},{"id":"cursor-context:composer-1:bubble-user-1","kind":"tool_activity","title":"Cursor 요청 맥락","body":"files: internal/agent/session_store.go","at":1700000000101}]}`),
	)
	repeatRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(repeatRec, repeatReq)
	if repeatRec.Code != http.StatusOK {
		t.Fatalf("expected 200 on repeated append, got %d", repeatRec.Code)
	}

	var repeated SharedSessionDetail
	if err := json.Unmarshal(repeatRec.Body.Bytes(), &repeated); err != nil {
		t.Fatalf("decode repeated append response: %v", err)
	}
	if len(repeated.Timeline) != 5 {
		t.Fatalf("expected idempotent append to keep timeline length 5, got %+v", repeated.Timeline)
	}
}

func TestHTTPServerSessionStreamEndpoint(t *testing.T) {
	server, _, _ := newTestHTTPServer()
	sessionID := seedSharedSession(t, server, "sid-live-stream", "Stream the shared session")

	httpServer := httptest.NewServer(server.Handler())
	defer httpServer.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	streamReq, err := http.NewRequestWithContext(ctx, http.MethodGet, httpServer.URL+"/v1/agent/sessions/"+sessionID+"/stream", nil)
	if err != nil {
		t.Fatalf("build stream request: %v", err)
	}
	streamResp, err := httpServer.Client().Do(streamReq)
	if err != nil {
		t.Fatalf("open stream: %v", err)
	}
	defer streamResp.Body.Close()

	if streamResp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", streamResp.StatusCode)
	}
	if !strings.HasPrefix(streamResp.Header.Get("Content-Type"), "text/event-stream") {
		t.Fatalf("expected text/event-stream content type, got %q", streamResp.Header.Get("Content-Type"))
	}

	reader := bufio.NewReader(streamResp.Body)
	firstDetail := readNextSessionStreamEvent(t, reader)
	if firstDetail.Session.ID != sessionID {
		t.Fatalf("expected first streamed session %s, got %+v", sessionID, firstDetail.Session)
	}
	if firstDetail.OperationState.Phase != "reviewing" {
		t.Fatalf("expected reviewing phase, got %+v", firstDetail.OperationState)
	}

	liveReq, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		httpServer.URL+"/v1/agent/sessions/"+sessionID+"/live",
		bytes.NewBufferString(`{"participant":{"participantId":"cursor-panel","clientType":"cursor_panel","displayName":"Cursor Panel","active":true,"lastSeenAt":1700000000010},"composer":{"draftText":"streamed draft","isTyping":true,"updatedAt":1700000000011},"activity":{"phase":"reviewing","summary":"Cursor 패널에서 검토 중","updatedAt":1700000000012},"reasoning":{"title":"stream reasoning","summary":"패치 검토 포인트를 공유 중","sourceKind":"manual","updatedAt":1700000000013},"terminal":{"status":"running","profileId":"test_all","command":"go test ./...","summary":"running tests","updatedAt":1700000000014}}`),
	)
	if err != nil {
		t.Fatalf("build live update request: %v", err)
	}
	liveReq.Header.Set("Content-Type", "application/json")
	liveResp, err := httpServer.Client().Do(liveReq)
	if err != nil {
		t.Fatalf("post live update: %v", err)
	}
	liveResp.Body.Close()
	if liveResp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 from live update, got %d", liveResp.StatusCode)
	}

	nextDetail := readNextSessionStreamEvent(t, reader)
	if nextDetail.LiveState.Composer.DraftText != "streamed draft" || !nextDetail.LiveState.Composer.IsTyping {
		t.Fatalf("expected streamed composer update, got %+v", nextDetail.LiveState.Composer)
	}
	if len(nextDetail.LiveState.Participants) == 0 || nextDetail.LiveState.Participants[0].ParticipantID != "cursor-panel" {
		t.Fatalf("expected streamed participant update, got %+v", nextDetail.LiveState.Participants)
	}
	if nextDetail.LiveState.Activity.Summary != "Cursor 패널에서 검토 중" {
		t.Fatalf("expected streamed activity update, got %+v", nextDetail.LiveState.Activity)
	}
	if nextDetail.LiveState.Reasoning.Title != "stream reasoning" || nextDetail.LiveState.Terminal.Command != "go test ./..." {
		t.Fatalf("expected streamed reasoning/terminal update, got %+v / %+v", nextDetail.LiveState.Reasoning, nextDetail.LiveState.Terminal)
	}
}

func seedSharedSession(t *testing.T, server *HTTPServer, sid string, prompt string) string {
	t.Helper()

	submitReq := httptest.NewRequest(
		http.MethodPost,
		"/v1/agent/envelope",
		bytes.NewBufferString(`{"sid":"`+sid+`","rid":"rid-seed","seq":1,"ts":1700000000000,"type":"PROMPT_SUBMIT","payload":{"prompt":"`+prompt+`","contextOptions":{}}}`),
	)
	submitRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(submitRec, submitReq)
	if submitRec.Code != http.StatusOK {
		t.Fatalf("submit response should be 200, got %d", submitRec.Code)
	}

	sessionsReq := httptest.NewRequest(http.MethodGet, "/v1/agent/sessions", nil)
	sessionsRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(sessionsRec, sessionsReq)
	if sessionsRec.Code != http.StatusOK {
		t.Fatalf("sessions response should be 200, got %d", sessionsRec.Code)
	}

	var sessionsBody struct {
		Sessions []SharedSessionSummary `json:"sessions"`
	}
	if err := json.Unmarshal(sessionsRec.Body.Bytes(), &sessionsBody); err != nil {
		t.Fatalf("decode sessions response: %v", err)
	}
	if len(sessionsBody.Sessions) == 0 {
		t.Fatalf("expected shared session to exist")
	}
	return sessionsBody.Sessions[0].ID
}

func readNextSessionStreamEvent(t *testing.T, reader *bufio.Reader) SharedSessionDetail {
	t.Helper()

	dataLines := make([]string, 0, 4)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read session stream event: %v", err)
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			if len(dataLines) == 0 {
				continue
			}

			var detail SharedSessionDetail
			if err := json.Unmarshal([]byte(strings.Join(dataLines, "\n")), &detail); err != nil {
				t.Fatalf("decode session stream payload: %v", err)
			}
			return detail
		}
		if strings.HasPrefix(line, ":") {
			continue
		}
		if strings.HasPrefix(line, "data:") {
			dataLines = append(dataLines, strings.TrimSpace(strings.TrimPrefix(line, "data:")))
		}
	}
}
