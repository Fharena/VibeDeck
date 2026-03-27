package agent

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Fharena/VibeDeck/internal/protocol"
)

type Orchestrator struct {
	adapter      WorkspaceAdapter
	profiles     map[string]RunProfile
	threadStore  *ThreadStore
	sessionStore *SessionStore

	mu   sync.RWMutex
	jobs map[string]*Job

	seq atomic.Int64
}

func NewOrchestrator(adapter WorkspaceAdapter, profiles map[string]RunProfile, threadStore *ThreadStore) *Orchestrator {
	if profiles == nil {
		profiles = DefaultRunProfiles()
	}
	if threadStore == nil {
		threadStore = NewThreadStore()
	}

	adapterInfo := BasicAdapterRuntimeInfo(adapter)
	if provider, ok := adapter.(AdapterRuntimeInfoProvider); ok {
		adapterInfo = provider.RuntimeInfo()
	}

	return &Orchestrator{
		adapter:      adapter,
		profiles:     profiles,
		threadStore:  threadStore,
		sessionStore: NewSessionStore(threadStore, adapterInfo),
		jobs:         make(map[string]*Job),
	}
}

func (o *Orchestrator) HandleEnvelope(ctx context.Context, env protocol.Envelope) ([]protocol.Envelope, error) {
	if err := env.Validate(); err != nil {
		return o.ackFail(env, "invalid envelope: "+err.Error(), err)
	}

	switch env.Type {
	case protocol.TypePromptSubmit:
		return o.handlePromptSubmit(ctx, env)
	case protocol.TypePatchApply:
		return o.handlePatchApply(ctx, env)
	case protocol.TypeRunProfile:
		return o.handleRunProfile(ctx, env)
	case protocol.TypeOpenLocation:
		return o.handleOpenLocation(ctx, env)
	default:
		return o.ackFail(env, "unsupported message type", errors.New("unsupported message type"))
	}
}

func (o *Orchestrator) RunProfiles() []RunProfileDescriptor {
	return RunProfileDescriptors(o.profiles)
}

func (o *Orchestrator) ThreadStore() *ThreadStore {
	return o.threadStore
}

func (o *Orchestrator) SessionStore() *SessionStore {
	return o.sessionStore
}

func (o *Orchestrator) handlePromptSubmit(ctx context.Context, env protocol.Envelope) ([]protocol.Envelope, error) {
	var payload protocol.PromptSubmitPayload
	if err := env.DecodePayload(&payload); err != nil {
		return o.ackFail(env, "invalid prompt payload", err)
	}

	if payload.Prompt == "" {
		return o.ackFail(env, "prompt is required", errors.New("prompt is required"))
	}

	threadSummary := o.threadStore.EnsureThread(payload.ThreadID, env.SID, payload.Prompt)
	threadID := threadSummary.ID

	contextData, err := o.adapter.GetContext(ctx, ContextRequest{Options: payload.ContextOptions})
	if err != nil {
		return o.ackFail(env, "adapter get context failed", err)
	}

	_, _ = o.threadStore.AppendEvent(threadID, ThreadEvent{
		JobID: "",
		Kind:  "prompt_submitted",
		Role:  "user",
		Title: "프롬프트 제출",
		Body:  payload.Prompt,
		Data: map[string]any{
			"template":       payload.Template,
			"model":          payload.Model,
			"reasoningLevel": payload.ReasoningLevel,
			"activeFilePath": contextData.ActiveFilePath,
			"selection":      contextData.Selection,
			"changedFiles":   contextData.ChangedFiles,
		},
	})

	taskHandle, err := o.adapter.SubmitTask(ctx, SubmitTaskInput{
		Prompt:         payload.Prompt,
		Template:       payload.Template,
		Model:          payload.Model,
		ReasoningLevel: payload.ReasoningLevel,
		Context:        contextData,
	})
	if err != nil {
		return o.ackFail(env, "adapter submit task failed", err)
	}

	patch, err := o.adapter.GetPatch(ctx, taskHandle.TaskID)
	if err != nil {
		return o.ackFail(env, "adapter get patch failed", err)
	}
	if patch == nil {
		return o.ackFail(env, "patch is not ready", errors.New("patch is nil"))
	}

	jobID := o.newID("job")
	patchFiles := patchFilePaths(patch.Files)
	o.mu.Lock()
	o.jobs[jobID] = &Job{
		ID:         jobID,
		ThreadID:   threadID,
		SessionID:  env.SID,
		TaskID:     taskHandle.TaskID,
		Prompt:     payload.Prompt,
		State:      "patch_ready",
		PatchFiles: patchFiles,
		CreatedAt:  time.Now().UTC(),
	}
	o.mu.Unlock()
	o.threadStore.AssignJob(threadID, jobID)

	_, _ = o.threadStore.AppendEvent(threadID, ThreadEvent{
		JobID: jobID,
		Kind:  "prompt_accepted",
		Role:  "system",
		Title: "작업 시작",
		Body:  "프롬프트를 받아 패치를 생성합니다.",
		Data: map[string]any{
			"taskId":  taskHandle.TaskID,
			"message": "task started",
		},
	})
	appendProviderVisibleEvents(o.threadStore, threadID, jobID, taskHandle.ProviderEvents)

	patch.JobID = jobID
	_, _ = o.threadStore.AppendEvent(threadID, ThreadEvent{
		JobID: jobID,
		Kind:  "patch_ready",
		Role:  "assistant",
		Title: "패치 준비 완료",
		Body:  patch.Summary,
		Data: map[string]any{
			"jobId":     jobID,
			"summary":   patch.Summary,
			"fileCount": len(patch.Files),
			"files":     patch.Files,
		},
	})

	ack, _ := protocol.NewCmdAck(env.SID, o.nextSeq(), env.RID, true, "accepted")
	promptAck, _ := protocol.NewEnvelope(env.SID, o.newID("prompt_ack"), o.nextSeq(), protocol.TypePromptAck, protocol.PromptAckPayload{
		ThreadID: threadID,
		JobID:    jobID,
		Accepted: true,
		Message:  "task started",
	})
	patchReady, _ := protocol.NewEnvelope(env.SID, o.newID("patch_ready"), o.nextSeq(), protocol.TypePatchReady, patch)
	autoApplyPayload := protocol.PatchApplyPayload{
		JobID: jobID,
		Mode:  "all",
	}
	autoApplyResult, autoApplyErr := o.applyPatchForJob(
		ctx,
		jobID,
		autoApplyPayload,
		"system",
		"기본 변경 반영",
	)
	patchResult, _ := protocol.NewEnvelope(
		env.SID,
		o.newID("patch_result"),
		o.nextSeq(),
		protocol.TypePatchResult,
		autoApplyResult,
	)

	if autoApplyErr != nil {
		return []protocol.Envelope{ack, promptAck, patchReady, patchResult}, nil
	}

	return []protocol.Envelope{ack, promptAck, patchReady, patchResult}, nil
}

func (o *Orchestrator) handlePatchApply(ctx context.Context, env protocol.Envelope) ([]protocol.Envelope, error) {
	var payload protocol.PatchApplyPayload
	if err := env.DecodePayload(&payload); err != nil {
		return o.ackFail(env, "invalid patch apply payload", err)
	}

	result, err := o.applyPatchForJob(ctx, payload.JobID, payload, "user", "패치 적용 요청")
	if err != nil {
		ack, _ := protocol.NewCmdAck(env.SID, o.nextSeq(), env.RID, false, err.Error())
		patchResult, _ := protocol.NewEnvelope(env.SID, o.newID("patch_result"), o.nextSeq(), protocol.TypePatchResult, result)
		return []protocol.Envelope{ack, patchResult}, err
	}

	ack, _ := protocol.NewCmdAck(env.SID, o.nextSeq(), env.RID, true, "patch apply queued")
	patchResult, _ := protocol.NewEnvelope(env.SID, o.newID("patch_result"), o.nextSeq(), protocol.TypePatchResult, result)

	return []protocol.Envelope{ack, patchResult}, nil
}

func (o *Orchestrator) applyPatchForJob(
	ctx context.Context,
	jobID string,
	payload protocol.PatchApplyPayload,
	role string,
	title string,
) (protocol.PatchResultPayload, error) {
	job, ok := o.getJob(jobID)
	if !ok {
		return protocol.PatchResultPayload{
			JobID:   jobID,
			Status:  "failed",
			Message: fmt.Sprintf("job %s not found", jobID),
		}, fmt.Errorf("job %s not found", jobID)
	}

	_, _ = o.threadStore.AppendEvent(job.ThreadID, ThreadEvent{
		JobID: job.ID,
		Kind:  "patch_apply_requested",
		Role:  role,
		Title: title,
		Body:  fmt.Sprintf("mode=%s", payload.Mode),
		Data: map[string]any{
			"mode":          payload.Mode,
			"selectedCount": len(payload.Selected),
		},
	})

	result, err := o.adapter.ApplyPatch(ctx, ApplyPatchInput{
		TaskID:   job.TaskID,
		Mode:     payload.Mode,
		Selected: payload.Selected,
	})
	if err != nil {
		_, _ = o.threadStore.AppendEvent(job.ThreadID, ThreadEvent{
			JobID: job.ID,
			Kind:  "patch_applied",
			Role:  "system",
			Title: "변경 반영 실패",
			Body:  err.Error(),
			Data: map[string]any{
				"status":  "failed",
				"message": err.Error(),
			},
		})
		o.setJobState(job.ID, "failed")
		return protocol.PatchResultPayload{
			JobID:   payload.JobID,
			Status:  "failed",
			Message: err.Error(),
		}, err
	}

	status := strings.ToLower(strings.TrimSpace(result.Status))
	if status == "failed" {
		o.setJobState(job.ID, "failed")
	} else {
		o.setJobState(job.ID, "applied")
	}

	_, _ = o.threadStore.AppendEvent(job.ThreadID, ThreadEvent{
		JobID: job.ID,
		Kind:  "patch_applied",
		Role:  "system",
		Title: "변경 반영 결과",
		Body:  result.Message,
		Data: map[string]any{
			"status":  result.Status,
			"message": result.Message,
		},
	})

	return protocol.PatchResultPayload{
		JobID:   payload.JobID,
		Status:  result.Status,
		Message: result.Message,
	}, nil
}

func (o *Orchestrator) handleRunProfile(ctx context.Context, env protocol.Envelope) ([]protocol.Envelope, error) {
	var payload protocol.RunProfilePayload
	if err := env.DecodePayload(&payload); err != nil {
		return o.ackFail(env, "invalid run profile payload", err)
	}

	job, ok := o.getJob(payload.JobID)
	if !ok {
		return o.ackFail(env, "job not found", fmt.Errorf("job %s not found", payload.JobID))
	}

	profile, ok := o.profiles[payload.ProfileID]
	if !ok {
		return o.ackFail(env, "unknown run profile", fmt.Errorf("profile %s not found", payload.ProfileID))
	}

	_, _ = o.threadStore.AppendEvent(job.ThreadID, ThreadEvent{
		JobID: job.ID,
		Kind:  "run_requested",
		Role:  "user",
		Title: "실행 요청",
		Body:  firstNonEmptyText(profile.Label, payload.ProfileID),
		Data: map[string]any{
			"profileId": payload.ProfileID,
			"label":     profile.Label,
			"command":   profile.Command,
		},
	})

	runHandle, err := o.adapter.RunProfile(ctx, RunProfileInput{
		TaskID:    job.TaskID,
		JobID:     payload.JobID,
		ProfileID: payload.ProfileID,
		Command:   profile.Command,
	})
	if err != nil {
		return o.ackFail(env, "run profile execution failed", err)
	}

	runResult, err := o.adapter.GetRunResult(ctx, runHandle.RunID)
	if err != nil {
		return o.ackFail(env, "failed to fetch run result", err)
	}
	if runResult == nil {
		return o.ackFail(env, "run result is empty", errors.New("run result is nil"))
	}

	changedFiles := append([]string(nil), runResult.ChangedFiles...)
	if len(changedFiles) == 0 {
		changedFiles = append(changedFiles, job.PatchFiles...)
	}

	o.setJobState(payload.JobID, "completed")
	_, _ = o.threadStore.AppendEvent(job.ThreadID, ThreadEvent{
		JobID: job.ID,
		Kind:  "run_finished",
		Role:  "system",
		Title: "실행 결과",
		Body:  firstNonEmptyText(runResult.Summary, runResult.Excerpt),
		Data: map[string]any{
			"profileId":    payload.ProfileID,
			"status":       runResult.Status,
			"summary":      runResult.Summary,
			"excerpt":      runResult.Excerpt,
			"output":       runResult.Output,
			"topErrors":    runResult.TopErrors,
			"changedFiles": changedFiles,
		},
	})
	appendProviderVisibleEvents(o.threadStore, job.ThreadID, job.ID, runResult.ProviderEvents)

	ack, _ := protocol.NewCmdAck(env.SID, o.nextSeq(), env.RID, true, "run started")
	resultEnvelope, _ := protocol.NewEnvelope(env.SID, o.newID("run_result"), o.nextSeq(), protocol.TypeRunResult, protocol.RunResultPayload{
		JobID:        payload.JobID,
		ProfileID:    runResult.ProfileID,
		Status:       runResult.Status,
		Summary:      runResult.Summary,
		TopErrors:    runResult.TopErrors,
		Excerpt:      runResult.Excerpt,
		Output:       runResult.Output,
		ChangedFiles: changedFiles,
	})

	return []protocol.Envelope{ack, resultEnvelope}, nil
}

func (o *Orchestrator) handleOpenLocation(ctx context.Context, env protocol.Envelope) ([]protocol.Envelope, error) {
	var payload protocol.OpenLocationPayload
	if err := env.DecodePayload(&payload); err != nil {
		return o.ackFail(env, "invalid open location payload", err)
	}

	if err := o.adapter.OpenLocation(ctx, OpenLocationInput{
		Path:   payload.Path,
		Line:   payload.Line,
		Column: payload.Column,
	}); err != nil {
		return o.ackFail(env, "open location failed", err)
	}

	ack, _ := protocol.NewCmdAck(env.SID, o.nextSeq(), env.RID, true, "location opened")
	return []protocol.Envelope{ack}, nil
}

func appendProviderVisibleEvents(store *ThreadStore, threadID, jobID string, events []ProviderVisibleEvent) {
	if store == nil || threadID == "" || len(events) == 0 {
		return
	}

	for _, event := range events {
		kind := strings.TrimSpace(event.Kind)
		if kind == "" {
			kind = "provider_message"
		}
		role := strings.TrimSpace(event.Role)
		if role == "" {
			role = "assistant"
		}

		data := map[string]any{}
		for key, value := range event.Data {
			data[key] = value
		}

		_, _ = store.AppendEvent(threadID, ThreadEvent{
			JobID: jobID,
			Kind:  kind,
			Role:  role,
			Title: event.Title,
			Body:  event.Body,
			Data:  data,
		})
	}
}

func (o *Orchestrator) ackFail(env protocol.Envelope, message string, err error) ([]protocol.Envelope, error) {
	sid := env.SID
	if sid == "" {
		sid = "unknown"
	}
	rid := env.RID
	if rid == "" {
		rid = o.newID("rid")
	}

	ack, ackErr := protocol.NewCmdAck(sid, o.nextSeq(), rid, false, message)
	if ackErr != nil {
		return nil, fmt.Errorf("build ack: %w", ackErr)
	}

	return []protocol.Envelope{ack}, err
}

func (o *Orchestrator) nextSeq() int64 {
	return o.seq.Add(1)
}

func (o *Orchestrator) newID(prefix string) string {
	return fmt.Sprintf("%s_%d", prefix, time.Now().UTC().UnixNano())
}

func (o *Orchestrator) getJob(jobID string) (*Job, bool) {
	o.mu.RLock()
	defer o.mu.RUnlock()

	job, ok := o.jobs[jobID]
	return job, ok
}

func (o *Orchestrator) setJobState(jobID, state string) {
	o.mu.Lock()
	defer o.mu.Unlock()

	if job, ok := o.jobs[jobID]; ok {
		job.State = state
	}
}

func patchFilePaths(files []protocol.FilePatch) []string {
	if len(files) == 0 {
		return nil
	}

	seen := make(map[string]struct{}, len(files))
	paths := make([]string, 0, len(files))
	for _, file := range files {
		if file.Path == "" {
			continue
		}
		if _, ok := seen[file.Path]; ok {
			continue
		}
		seen[file.Path] = struct{}{}
		paths = append(paths, file.Path)
	}
	return paths
}
