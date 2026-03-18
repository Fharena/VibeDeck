package agent

import (
	"testing"

	"github.com/Fharena/VibeDeck/internal/protocol"
)

func TestSessionStoreBuildsReadModelFromThreadDetail(t *testing.T) {
	threadStore := NewThreadStore()
	threadStore.EnsureThread("thread-1", "sid-1", "Fix auth middleware")
	threadStore.AssignJob("thread-1", "job-1")

	_, _ = threadStore.AppendEvent("thread-1", ThreadEvent{
		JobID: "job-1",
		Kind:  "prompt_submitted",
		Role:  "user",
		Body:  "Fix auth middleware",
		Data: map[string]any{
			"activeFilePath": "middleware/auth.go",
			"selection":      "requireUser",
		},
	})
	_, _ = threadStore.AppendEvent("thread-1", ThreadEvent{
		JobID: "job-1",
		Kind:  "patch_ready",
		Role:  "assistant",
		Body:  "auth patch",
		Data: map[string]any{
			"summary": "auth patch",
			"files": []protocol.FilePatch{
				{Path: "middleware/auth.go", Status: "modified"},
			},
		},
	})
	_, _ = threadStore.AppendEvent("thread-1", ThreadEvent{
		JobID: "job-1",
		Kind:  "run_finished",
		Role:  "system",
		Body:  "tests failed",
		Data: map[string]any{
			"profileId": "test_all",
			"status":    "failed",
			"summary":   "tests failed",
			"excerpt":   "FAIL\tmiddleware",
			"output":    "FAIL\tmiddleware\nexpected 200",
			"changedFiles": []string{
				"middleware/auth.go",
			},
			"topErrors": []protocol.ParsedError{
				{Path: "middleware/auth_test.go", Line: 27, Message: "expected 200"},
			},
		},
	})

	store := NewSessionStore(threadStore, AdapterRuntimeInfo{
		Name:          "mock-cursor",
		Mode:          "cursor_bridge",
		WorkspaceRoot: `C:\repo\workspace`,
	})

	detail, ok := store.Get("thread-1")
	if !ok {
		t.Fatalf("expected session detail to exist")
	}
	if detail.Session.ID != "thread-1" {
		t.Fatalf("expected session id thread-1, got %+v", detail.Session)
	}
	if detail.Session.ControlSessionID != "sid-1" {
		t.Fatalf("expected control session id sid-1, got %+v", detail.Session)
	}
	if detail.Session.Provider != "cursor" {
		t.Fatalf("expected provider cursor, got %+v", detail.Session)
	}
	if detail.OperationState.Phase != "waiting_input" {
		t.Fatalf("expected phase waiting_input, got %+v", detail.OperationState)
	}
	if detail.OperationState.CurrentJobID != "job-1" {
		t.Fatalf("expected current job id job-1, got %+v", detail.OperationState)
	}
	if detail.OperationState.PatchSummary != "auth patch" {
		t.Fatalf("expected patch summary auth patch, got %+v", detail.OperationState)
	}
	if detail.OperationState.RunProfileID != "test_all" {
		t.Fatalf("expected run profile id test_all, got %+v", detail.OperationState)
	}
	if detail.OperationState.LastError != "tests failed" {
		t.Fatalf("expected last error tests failed, got %+v", detail.OperationState)
	}
	if len(detail.OperationState.PatchFiles) != 1 || detail.OperationState.PatchFiles[0] != "middleware/auth.go" {
		t.Fatalf("expected patch files to include middleware/auth.go, got %+v", detail.OperationState.PatchFiles)
	}
	if detail.OperationState.RunExcerpt != "FAIL\tmiddleware" || detail.OperationState.RunOutput == "" {
		t.Fatalf("expected run terminal fields, got %+v", detail.OperationState)
	}
	if len(detail.OperationState.RunChangedFiles) != 1 || detail.OperationState.RunChangedFiles[0] != "middleware/auth.go" {
		t.Fatalf("expected run changed files to include middleware/auth.go, got %+v", detail.OperationState.RunChangedFiles)
	}
	if len(detail.OperationState.RunTopErrors) != 1 || detail.OperationState.RunTopErrors[0].Path != "middleware/auth_test.go" {
		t.Fatalf("expected run top errors to be populated, got %+v", detail.OperationState.RunTopErrors)
	}
	if len(detail.OperationState.CurrentJobFiles) != 1 || detail.OperationState.CurrentJobFiles[0] != "middleware/auth.go" {
		t.Fatalf("expected current job files to include middleware/auth.go, got %+v", detail.OperationState.CurrentJobFiles)
	}
	if detail.LiveState.Composer.DraftText != "Fix auth middleware" {
		t.Fatalf("expected composer draft from prompt, got %+v", detail.LiveState)
	}
	if detail.LiveState.Focus.ActiveFilePath != "middleware/auth.go" {
		t.Fatalf("expected active file path middleware/auth.go, got %+v", detail.LiveState.Focus)
	}
	if detail.LiveState.Focus.PatchPath != "middleware/auth.go" {
		t.Fatalf("expected patch path middleware/auth.go, got %+v", detail.LiveState.Focus)
	}
	if detail.LiveState.Focus.RunErrorPath != "middleware/auth_test.go" || detail.LiveState.Focus.RunErrorLine != 27 {
		t.Fatalf("expected run error focus from top errors, got %+v", detail.LiveState.Focus)
	}
	if detail.LiveState.Reasoning.Summary != "tests failed" || detail.LiveState.Reasoning.SourceKind != "run_finished" {
		t.Fatalf("expected reasoning summary from latest agent event, got %+v", detail.LiveState.Reasoning)
	}
	if len(detail.LiveState.Plan.Items) != 4 || detail.LiveState.Plan.Items[3].Status != "failed" {
		t.Fatalf("expected plan trace to be populated, got %+v", detail.LiveState.Plan)
	}
	if len(detail.LiveState.Tools.Activities) != 3 || detail.LiveState.Tools.CurrentStatus != "failed" {
		t.Fatalf("expected tool activities to be populated, got %+v", detail.LiveState.Tools)
	}
	if detail.LiveState.Terminal.Status != "failed" || detail.LiveState.Terminal.Output == "" {
		t.Fatalf("expected terminal state to be populated, got %+v", detail.LiveState.Terminal)
	}
	if detail.LiveState.Workspace.RootPath != `C:\repo\workspace` || detail.LiveState.Workspace.ActiveFilePath != "middleware/auth.go" {
		t.Fatalf("expected workspace state to be populated, got %+v", detail.LiveState.Workspace)
	}
}

func TestSessionStoreDerivesCursorContextIntoSharedLiveState(t *testing.T) {
	threadStore := NewThreadStore()
	threadStore.EnsureThread("thread-cursor-context", "sid-cursor-context", "Cursor regular chat")

	_, _ = threadStore.AppendEvent("thread-cursor-context", ThreadEvent{
		Kind: "prompt_submitted",
		Role: "user",
		Body: "삼성전자 동향을 정리해줘",
		At:   1700000000100,
	})
	_, _ = threadStore.AppendEvent("thread-cursor-context", ThreadEvent{
		Kind:  "provider_message",
		Role:  "assistant",
		Title: "Cursor 응답",
		Body:  "먼저 최근 삼성전자 동향을 정리하고 필요한 파일을 준비하겠습니다.",
		Data: map[string]any{
			"source": "cursor_storage",
		},
		At: 1700000000200,
	})
	_, _ = threadStore.AppendEvent("thread-cursor-context", ThreadEvent{
		Kind:  "tool_activity",
		Role:  "system",
		Title: "Cursor 요청 맥락",
		Body:  "files: reports/demo.md | terminal: rg 삼성전자, npm test | todos: 2",
		Data: map[string]any{
			"source":           "cursor_storage",
			"files":            []string{"reports/demo.md", "README.md"},
			"terminalCommands": []string{"rg 삼성전자", "npm test"},
			"todos": []any{
				map[string]any{
					"id":        "collect-data",
					"title":     "시장 데이터 확인",
					"status":    "in_progress",
					"detail":    "최근 기사와 수급 데이터를 확인합니다.",
					"updatedAt": 1700000000300,
				},
				map[string]any{
					"id":          "write-report",
					"title":       "보고서 초안 작성",
					"description": "reports/demo.md 초안을 정리합니다.",
					"completed":   false,
				},
			},
		},
		At: 1700000000300,
	})

	store := NewSessionStore(threadStore, AdapterRuntimeInfo{
		Name:          "cursor-bridge",
		Mode:          "cursor_bridge",
		WorkspaceRoot: `C:\repo\workspace`,
	})

	detail, ok := store.Get("thread-cursor-context")
	if !ok {
		t.Fatalf("expected session detail to exist")
	}
	if detail.LiveState.Reasoning.Summary != "먼저 최근 삼성전자 동향을 정리하고 필요한 파일을 준비하겠습니다." || detail.LiveState.Reasoning.SourceKind != "provider_message" {
		t.Fatalf("expected assistant provider message to drive reasoning, got %+v", detail.LiveState.Reasoning)
	}
	if len(detail.LiveState.Plan.Items) != 2 || detail.LiveState.Plan.Items[0].Label != "시장 데이터 확인" || detail.LiveState.Plan.Items[0].Status != "in_progress" {
		t.Fatalf("expected Cursor todos to drive shared plan, got %+v", detail.LiveState.Plan)
	}
	if detail.LiveState.Tools.CurrentLabel != "작업 계획" || len(detail.LiveState.Tools.Activities) != 2 {
		t.Fatalf("expected tool activity to include Cursor context, got %+v", detail.LiveState.Tools)
	}
	if detail.LiveState.Terminal.Status != "context" || detail.LiveState.Terminal.Command != "rg 삼성전자" {
		t.Fatalf("expected Cursor terminal context to populate terminal state, got %+v", detail.LiveState.Terminal)
	}
	if detail.LiveState.Workspace.ActiveFilePath != "reports/demo.md" || detail.LiveState.Focus.ActiveFilePath != "reports/demo.md" {
		t.Fatalf("expected Cursor file context to populate workspace/focus, got %+v / %+v", detail.LiveState.Workspace, detail.LiveState.Focus)
	}
}

func TestSessionStoreMergesLiveOverrides(t *testing.T) {
	threadStore := NewThreadStore()
	threadStore.EnsureThread("thread-override", "sid-2", "Override test")

	store := NewSessionStore(threadStore, AdapterRuntimeInfo{})
	store.UpsertParticipant("thread-override", SessionParticipant{
		ParticipantID: "mobile-1",
		ClientType:    "mobile",
		DisplayName:   "iPhone",
		Active:        true,
		LastSeenAt:    100,
	})
	store.UpdateComposer("thread-override", SessionComposerState{
		DraftText: "새 draft",
		IsTyping:  true,
		UpdatedAt: 101,
	})
	store.UpdateFocus("thread-override", SessionFocusState{
		ActiveFilePath: "mobile/app.dart",
		Selection:      "build",
		UpdatedAt:      102,
	})
	store.UpdateReasoning("thread-override", SessionReasoningState{
		Title:      "분석 요약",
		Summary:    "모바일과 Cursor가 같은 세션을 보고 있습니다.",
		SourceKind: "manual",
		UpdatedAt:  103,
	})
	store.UpdatePlan("thread-override", SessionPlanState{
		Summary:   "공통 세션 계획",
		Items:     []SessionPlanItem{{ID: "sync", Label: "동기화", Status: "in_progress", Detail: "양쪽 draft를 맞추는 중", UpdatedAt: 104}},
		UpdatedAt: 104,
	})
	store.UpdateTools("thread-override", SessionToolState{
		CurrentLabel:  "파일 탐색",
		CurrentStatus: "in_progress",
		Activities:    []SessionToolActivity{{Kind: "scan", Label: "파일 탐색", Status: "in_progress", Detail: "lib 폴더 확인 중", At: 105}},
		UpdatedAt:     105,
	})
	store.UpdateTerminal("thread-override", SessionTerminalState{
		Status:    "running",
		ProfileID: "test_all",
		Command:   "go test ./...",
		Summary:   "테스트 실행 중",
		UpdatedAt: 106,
	})
	store.UpdateWorkspace("thread-override", SessionWorkspaceState{
		RootPath:       `C:\repo\workspace`,
		ActiveFilePath: "mobile/app.dart",
		PatchFiles:     []string{"mobile/app.dart"},
		ChangedFiles:   []string{"mobile/app.dart"},
		UpdatedAt:      107,
	})

	detail, ok := store.Get("thread-override")
	if !ok {
		t.Fatalf("expected session detail to exist")
	}
	if len(detail.LiveState.Participants) != 1 || detail.LiveState.Participants[0].ParticipantID != "mobile-1" {
		t.Fatalf("expected live participant override, got %+v", detail.LiveState.Participants)
	}
	if detail.Session.ControlSessionID != "sid-2" {
		t.Fatalf("expected control session id sid-2, got %+v", detail.Session)
	}
	if detail.LiveState.Composer.DraftText != "새 draft" || !detail.LiveState.Composer.IsTyping {
		t.Fatalf("expected composer override, got %+v", detail.LiveState.Composer)
	}
	if detail.LiveState.Focus.ActiveFilePath != "mobile/app.dart" || detail.LiveState.Focus.Selection != "build" {
		t.Fatalf("expected focus override, got %+v", detail.LiveState.Focus)
	}
	if detail.LiveState.Reasoning.Title != "분석 요약" || detail.LiveState.Plan.Summary != "공통 세션 계획" {
		t.Fatalf("expected reasoning/plan override, got %+v / %+v", detail.LiveState.Reasoning, detail.LiveState.Plan)
	}
	if detail.LiveState.Tools.CurrentLabel != "파일 탐색" || detail.LiveState.Terminal.Command != "go test ./..." {
		t.Fatalf("expected tools/terminal override, got %+v / %+v", detail.LiveState.Tools, detail.LiveState.Terminal)
	}
	if detail.LiveState.Workspace.ActiveFilePath != "mobile/app.dart" || len(detail.LiveState.Workspace.PatchFiles) != 1 {
		t.Fatalf("expected workspace override, got %+v", detail.LiveState.Workspace)
	}
}

func TestSessionStoreLiveOverridesCanClearFields(t *testing.T) {
	threadStore := NewThreadStore()
	threadStore.EnsureThread("thread-clear", "sid-clear", "Clear override test")

	store := NewSessionStore(threadStore, AdapterRuntimeInfo{})
	store.UpdateComposer("thread-clear", SessionComposerState{
		DraftText: "temporary draft",
		IsTyping:  true,
		UpdatedAt: 201,
	})
	store.UpdateFocus("thread-clear", SessionFocusState{
		ActiveFilePath: "lib/main.dart",
		Selection:      "build",
		UpdatedAt:      202,
	})
	store.UpdateActivity("thread-clear", SessionActivityState{
		Phase:     "reviewing",
		Summary:   "Cursor가 검토 중",
		UpdatedAt: 203,
	})
	store.UpdateReasoning("thread-clear", SessionReasoningState{
		Title:      "요약",
		Summary:    "reasoning",
		SourceKind: "manual",
		UpdatedAt:  204,
	})
	store.UpdatePlan("thread-clear", SessionPlanState{
		Summary:   "plan",
		Items:     []SessionPlanItem{{ID: "a", Label: "A", Status: "completed", UpdatedAt: 205}},
		UpdatedAt: 205,
	})
	store.UpdateTools("thread-clear", SessionToolState{
		CurrentLabel:  "tool",
		CurrentStatus: "completed",
		Activities:    []SessionToolActivity{{Kind: "tool", Label: "tool", Status: "completed", At: 206}},
		UpdatedAt:     206,
	})
	store.UpdateTerminal("thread-clear", SessionTerminalState{
		Status:    "completed",
		ProfileID: "test_all",
		Command:   "go test ./...",
		UpdatedAt: 207,
	})
	store.UpdateWorkspace("thread-clear", SessionWorkspaceState{
		RootPath:       `C:\repo\workspace`,
		ActiveFilePath: "lib/main.dart",
		UpdatedAt:      208,
	})

	store.UpdateComposer("thread-clear", SessionComposerState{})
	store.UpdateFocus("thread-clear", SessionFocusState{})
	store.UpdateActivity("thread-clear", SessionActivityState{})
	store.UpdateReasoning("thread-clear", SessionReasoningState{})
	store.UpdatePlan("thread-clear", SessionPlanState{})
	store.UpdateTools("thread-clear", SessionToolState{})
	store.UpdateTerminal("thread-clear", SessionTerminalState{})
	store.UpdateWorkspace("thread-clear", SessionWorkspaceState{})

	detail, ok := store.Get("thread-clear")
	if !ok {
		t.Fatalf("expected session detail to exist")
	}
	if detail.LiveState.Composer.DraftText != "" || detail.LiveState.Composer.IsTyping {
		t.Fatalf("expected composer override to clear, got %+v", detail.LiveState.Composer)
	}
	if detail.LiveState.Focus.ActiveFilePath != "" || detail.LiveState.Focus.Selection != "" {
		t.Fatalf("expected focus override to clear, got %+v", detail.LiveState.Focus)
	}
	if detail.LiveState.Activity.Phase != "" || detail.LiveState.Activity.Summary != "" {
		t.Fatalf("expected activity override to clear, got %+v", detail.LiveState.Activity)
	}
	if detail.LiveState.Reasoning.Summary != "" || len(detail.LiveState.Plan.Items) != 0 {
		t.Fatalf("expected reasoning/plan override to clear, got %+v / %+v", detail.LiveState.Reasoning, detail.LiveState.Plan)
	}
	if detail.LiveState.Tools.CurrentLabel != "" || detail.LiveState.Terminal.Command != "" {
		t.Fatalf("expected tools/terminal override to clear, got %+v / %+v", detail.LiveState.Tools, detail.LiveState.Terminal)
	}
	if detail.LiveState.Workspace.ActiveFilePath != "" || detail.LiveState.Workspace.RootPath != "" {
		t.Fatalf("expected workspace override to clear, got %+v", detail.LiveState.Workspace)
	}
}
