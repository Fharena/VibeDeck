package agent

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Fharena/VibeDeck/internal/runtime"
)

type workspaceTestAdapter struct {
	*MockAdapter
	root string
}

func (a *workspaceTestAdapter) RuntimeInfo() AdapterRuntimeInfo {
	info := BasicAdapterRuntimeInfo(a.MockAdapter)
	info.WorkspaceRoot = a.root
	return info
}

func newWorkspaceHTTPServer(root string) *HTTPServer {
	adapter := &workspaceTestAdapter{
		MockAdapter: NewMockAdapter(),
		root:        root,
	}
	threadStore := NewThreadStore()
	orch := NewOrchestrator(adapter, DefaultRunProfiles(), threadStore)
	stateManager := runtime.NewStateManager(runtime.DefaultManagerConfig())
	ackTracker := runtime.NewAckTracker(2 * time.Second)
	controlMetrics := NewControlMetrics()
	p2pManager := NewP2PSessionManager(stateManager, ackTracker, orch, "http://127.0.0.1:8081")
	p2pManager.SetControlMetrics(controlMetrics)

	return NewHTTPServer(
		adapter,
		orch,
		stateManager,
		ackTracker,
		controlMetrics,
		p2pManager,
		HTTPServerConfig{},
	)
}

func TestHTTPServerWorkspaceTreeAndFileEndpoints(t *testing.T) {
	tempDir := t.TempDir()
	reportsDir := filepath.Join(tempDir, "reports")
	if err := os.MkdirAll(reportsDir, 0o755); err != nil {
		t.Fatalf("mkdir reports: %v", err)
	}
	if err := os.WriteFile(filepath.Join(tempDir, "README.md"), []byte("# demo\n"), 0o644); err != nil {
		t.Fatalf("write readme: %v", err)
	}
	if err := os.WriteFile(filepath.Join(reportsDir, "demo.md"), []byte("hello from workspace\n"), 0o644); err != nil {
		t.Fatalf("write demo file: %v", err)
	}

	server := newWorkspaceHTTPServer(tempDir)

	treeReq := httptest.NewRequest(http.MethodGet, "/v1/agent/workspace/tree", nil)
	treeRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(treeRec, treeReq)
	if treeRec.Code != http.StatusOK {
		t.Fatalf("expected 200 from root tree, got %d", treeRec.Code)
	}

	var treeBody WorkspaceTreeResponse
	if err := json.Unmarshal(treeRec.Body.Bytes(), &treeBody); err != nil {
		t.Fatalf("decode root tree: %v", err)
	}
	if treeBody.RootPath == "" {
		t.Fatalf("expected workspace root path in tree response")
	}
	if len(treeBody.Entries) < 2 {
		t.Fatalf("expected root tree entries, got %+v", treeBody.Entries)
	}

	reportsTreeReq := httptest.NewRequest(http.MethodGet, "/v1/agent/workspace/tree?path=reports", nil)
	reportsTreeRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(reportsTreeRec, reportsTreeReq)
	if reportsTreeRec.Code != http.StatusOK {
		t.Fatalf("expected 200 from reports tree, got %d", reportsTreeRec.Code)
	}

	var reportsBody WorkspaceTreeResponse
	if err := json.Unmarshal(reportsTreeRec.Body.Bytes(), &reportsBody); err != nil {
		t.Fatalf("decode reports tree: %v", err)
	}
	if len(reportsBody.Entries) != 1 || reportsBody.Entries[0].Path != "reports/demo.md" {
		t.Fatalf("expected demo.md entry, got %+v", reportsBody.Entries)
	}

	fileReq := httptest.NewRequest(http.MethodGet, "/v1/agent/workspace/file?path=reports/demo.md", nil)
	fileRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(fileRec, fileReq)
	if fileRec.Code != http.StatusOK {
		t.Fatalf("expected 200 from file read, got %d", fileRec.Code)
	}

	var fileBody WorkspaceFileResponse
	if err := json.Unmarshal(fileRec.Body.Bytes(), &fileBody); err != nil {
		t.Fatalf("decode file read: %v", err)
	}
	if fileBody.Content != "hello from workspace\n" {
		t.Fatalf("unexpected file content: %q", fileBody.Content)
	}

	updateReq := httptest.NewRequest(
		http.MethodPut,
		"/v1/agent/workspace/file?path=reports/demo.md",
		bytes.NewBufferString(`{"content":"updated from mobile\n"}`),
	)
	updateRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(updateRec, updateReq)
	if updateRec.Code != http.StatusOK {
		t.Fatalf("expected 200 from file write, got %d", updateRec.Code)
	}

	updatedBytes, err := os.ReadFile(filepath.Join(reportsDir, "demo.md"))
	if err != nil {
		t.Fatalf("read updated file: %v", err)
	}
	if string(updatedBytes) != "updated from mobile\n" {
		t.Fatalf("unexpected updated file content: %q", string(updatedBytes))
	}
}

func TestHTTPServerWorkspaceTreeIncludesSessionHints(t *testing.T) {
	tempDir := t.TempDir()
	reportsDir := filepath.Join(tempDir, "reports")
	if err := os.MkdirAll(reportsDir, 0o755); err != nil {
		t.Fatalf("mkdir reports: %v", err)
	}
	if err := os.WriteFile(filepath.Join(reportsDir, "demo.md"), []byte("hello\n"), 0o644); err != nil {
		t.Fatalf("write demo file: %v", err)
	}

	server := newWorkspaceHTTPServer(tempDir)
	sessionID := seedSharedSession(t, server, "sid-workspace-hints", "Inspect workspace file state")

	liveBody := bytes.NewBufferString(`{"focus":{"activeFilePath":"reports/demo.md","updatedAt":1700000000001},"workspace":{"rootPath":"C:\\repo\\workspace","activeFilePath":"reports/demo.md","patchFiles":["reports/demo.md"],"changedFiles":["reports/demo.md"],"updatedAt":1700000000002}}`)
	liveReq := httptest.NewRequest(http.MethodPost, "/v1/agent/sessions/"+sessionID+"/live", liveBody)
	liveRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(liveRec, liveReq)
	if liveRec.Code != http.StatusOK {
		t.Fatalf("expected 200 from live update, got %d", liveRec.Code)
	}

	treeReq := httptest.NewRequest(http.MethodGet, "/v1/agent/workspace/tree?path=reports&sessionId="+sessionID, nil)
	treeRec := httptest.NewRecorder()
	server.Handler().ServeHTTP(treeRec, treeReq)
	if treeRec.Code != http.StatusOK {
		t.Fatalf("expected 200 from workspace tree, got %d", treeRec.Code)
	}

	var treeBody WorkspaceTreeResponse
	if err := json.Unmarshal(treeRec.Body.Bytes(), &treeBody); err != nil {
		t.Fatalf("decode workspace tree: %v", err)
	}
	if len(treeBody.Entries) != 1 {
		t.Fatalf("expected a single file entry, got %+v", treeBody.Entries)
	}

	entry := treeBody.Entries[0]
	if !entry.IsActive || !entry.IsChanged || !entry.IsPatch {
		t.Fatalf("expected session hints on entry, got %+v", entry)
	}
}
