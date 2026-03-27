package agent

import (
	"context"
	"testing"

	"github.com/Fharena/VibeDeck/internal/protocol"
)

func TestOrchestratorPromptSubmitFlow(t *testing.T) {
	orch := NewOrchestrator(NewMockAdapter(), DefaultRunProfiles(), nil)

	env, err := protocol.NewEnvelope("sid-1", "rid-1", 1, protocol.TypePromptSubmit, protocol.PromptSubmitPayload{
		Prompt:   "Fix auth middleware",
		Template: "fix_bug",
		ContextOptions: protocol.ContextOptions{
			IncludeActiveFile: true,
		},
	})
	if err != nil {
		t.Fatalf("build envelope: %v", err)
	}

	responses, err := orch.HandleEnvelope(context.Background(), env)
	if err != nil {
		t.Fatalf("handle envelope: %v", err)
	}

	if len(responses) != 4 {
		t.Fatalf("expected 4 responses, got %d", len(responses))
	}

	if responses[0].Type != protocol.TypeCmdAck {
		t.Fatalf("response[0] should be CMD_ACK")
	}
	if responses[1].Type != protocol.TypePromptAck {
		t.Fatalf("response[1] should be PROMPT_ACK")
	}
	if responses[2].Type != protocol.TypePatchReady {
		t.Fatalf("response[2] should be PATCH_READY")
	}
	if responses[3].Type != protocol.TypePatchResult {
		t.Fatalf("response[3] should be PATCH_RESULT")
	}

	var promptAck protocol.PromptAckPayload
	if err := responses[1].DecodePayload(&promptAck); err != nil {
		t.Fatalf("decode prompt ack payload: %v", err)
	}
	if promptAck.JobID == "" {
		t.Fatalf("prompt ack job id should be set")
	}
	if promptAck.ThreadID == "" {
		t.Fatalf("prompt ack thread id should be set")
	}

	detail, ok := orch.ThreadStore().Get(promptAck.ThreadID)
	if !ok {
		t.Fatalf("thread detail should exist")
	}
	if len(detail.Events) != 5 {
		t.Fatalf("expected 5 thread events, got %+v", detail.Events)
	}
	if detail.Events[0].Kind != "prompt_submitted" {
		t.Fatalf("expected first event prompt_submitted, got %+v", detail.Events[0])
	}
	if detail.Events[2].Kind != "patch_ready" {
		t.Fatalf("expected patch_ready event, got %+v", detail.Events[2])
	}
	if detail.Events[3].Kind != "patch_apply_requested" {
		t.Fatalf("expected patch_apply_requested event, got %+v", detail.Events[3])
	}
	if detail.Events[4].Kind != "patch_applied" {
		t.Fatalf("expected patch_applied event, got %+v", detail.Events[4])
	}
}

func TestOrchestratorPatchApplyUnknownJob(t *testing.T) {
	orch := NewOrchestrator(NewMockAdapter(), DefaultRunProfiles(), nil)

	env, err := protocol.NewEnvelope("sid-1", "rid-apply", 2, protocol.TypePatchApply, protocol.PatchApplyPayload{
		JobID: "missing",
		Mode:  "all",
	})
	if err != nil {
		t.Fatalf("build envelope: %v", err)
	}

	responses, err := orch.HandleEnvelope(context.Background(), env)
	if err == nil {
		t.Fatalf("expected error for unknown job")
	}
	if len(responses) != 2 {
		t.Fatalf("expected CMD_ACK and PATCH_RESULT failure, got %+v", responses)
	}
	if responses[0].Type != protocol.TypeCmdAck || responses[1].Type != protocol.TypePatchResult {
		t.Fatalf("expected CMD_ACK then PATCH_RESULT failure, got %+v", responses)
	}
}

func TestOrchestratorRunProfileFlow(t *testing.T) {
	orch := NewOrchestrator(NewMockAdapter(), DefaultRunProfiles(), nil)

	submit, _ := protocol.NewEnvelope("sid-1", "rid-submit", 1, protocol.TypePromptSubmit, protocol.PromptSubmitPayload{
		Prompt: "Fix test",
	})

	submitResponses, err := orch.HandleEnvelope(context.Background(), submit)
	if err != nil {
		t.Fatalf("submit flow failed: %v", err)
	}

	var promptAck protocol.PromptAckPayload
	if err := submitResponses[1].DecodePayload(&promptAck); err != nil {
		t.Fatalf("decode prompt ack: %v", err)
	}

	runEnv, _ := protocol.NewEnvelope("sid-1", "rid-run", 2, protocol.TypeRunProfile, protocol.RunProfilePayload{
		JobID:     promptAck.JobID,
		ProfileID: "test_all",
	})

	runResponses, err := orch.HandleEnvelope(context.Background(), runEnv)
	if err != nil {
		t.Fatalf("run flow failed: %v", err)
	}

	if len(runResponses) != 2 {
		t.Fatalf("expected 2 responses for run profile, got %d", len(runResponses))
	}

	if runResponses[1].Type != protocol.TypeRunResult {
		t.Fatalf("second response should be RUN_RESULT")
	}

	var runResult protocol.RunResultPayload
	if err := runResponses[1].DecodePayload(&runResult); err != nil {
		t.Fatalf("decode run result: %v", err)
	}
	if len(runResult.ChangedFiles) == 0 {
		t.Fatalf("expected run result changed files, got %+v", runResult)
	}

	detail, ok := orch.ThreadStore().Get(promptAck.ThreadID)
	if !ok {
		t.Fatalf("thread detail should exist")
	}
	if detail.Thread.State != "failed" {
		t.Fatalf("expected thread state failed after mock run result, got %+v", detail.Thread)
	}
	if detail.Events[len(detail.Events)-1].Kind != "run_finished" {
		t.Fatalf("expected last event run_finished, got %+v", detail.Events[len(detail.Events)-1])
	}
}

type providerMockAdapter struct {
	*MockAdapter
}

func (a *providerMockAdapter) SubmitTask(_ context.Context, _ SubmitTaskInput) (TaskHandle, error) {
	handle, err := a.MockAdapter.SubmitTask(context.Background(), SubmitTaskInput{})
	if err != nil {
		return TaskHandle{}, err
	}
	handle.ProviderEvents = []ProviderVisibleEvent{{
		Kind:  "provider_message",
		Role:  "assistant",
		Title: "Cursor 응답",
		Body:  "문제를 분석했고 auth middleware 패치를 준비했습니다.",
		Data:  map[string]any{"source": "cursor_agent_cli"},
	}}
	return handle, nil
}

func TestOrchestratorPromptSubmitAppendsProviderVisibleEvents(t *testing.T) {
	orch := NewOrchestrator(&providerMockAdapter{MockAdapter: NewMockAdapter()}, DefaultRunProfiles(), nil)

	env, err := protocol.NewEnvelope("sid-provider", "rid-provider", 1, protocol.TypePromptSubmit, protocol.PromptSubmitPayload{
		Prompt: "Auth middleware를 고쳐줘",
	})
	if err != nil {
		t.Fatalf("build envelope: %v", err)
	}

	responses, err := orch.HandleEnvelope(context.Background(), env)
	if err != nil {
		t.Fatalf("handle envelope: %v", err)
	}

	var promptAck protocol.PromptAckPayload
	if err := responses[1].DecodePayload(&promptAck); err != nil {
		t.Fatalf("decode prompt ack payload: %v", err)
	}

	detail, ok := orch.ThreadStore().Get(promptAck.ThreadID)
	if !ok {
		t.Fatalf("thread detail should exist")
	}
	if len(detail.Events) != 6 {
		t.Fatalf("expected 6 thread events, got %+v", detail.Events)
	}
	providerEvent := detail.Events[2]
	if providerEvent.Kind != "provider_message" || providerEvent.Role != "assistant" {
		t.Fatalf("expected provider message event, got %+v", providerEvent)
	}
	if providerEvent.Body != "문제를 분석했고 auth middleware 패치를 준비했습니다." {
		t.Fatalf("expected mirrored provider body, got %+v", providerEvent)
	}
	if providerEvent.Data["source"] != "cursor_agent_cli" {
		t.Fatalf("expected provider source metadata, got %+v", providerEvent.Data)
	}
	if detail.Events[3].Kind != "patch_ready" {
		t.Fatalf("expected patch_ready after provider event, got %+v", detail.Events[3])
	}
	if detail.Events[4].Kind != "patch_apply_requested" {
		t.Fatalf("expected patch_apply_requested after patch_ready, got %+v", detail.Events[4])
	}
	if detail.Events[5].Kind != "patch_applied" {
		t.Fatalf("expected patch_applied after auto apply, got %+v", detail.Events[5])
	}
}
