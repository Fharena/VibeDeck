package agent

import (
	"context"
	"time"

	"github.com/Fharena/VibeDeck/internal/protocol"
)

type AdapterCapabilities struct {
	SupportsPartialApply     bool `json:"supportsPartialApply"`
	SupportsStructuredPatch  bool `json:"supportsStructuredPatch"`
	SupportsContextSelection bool `json:"supportsContextSelection"`
	SupportsArtifacts        bool `json:"supportsArtifacts"`
	SupportsOpenLocation     bool `json:"supportsOpenLocation"`
}

type ContextRequest struct {
	Options protocol.ContextOptions `json:"options"`
}

type WorkspaceContext struct {
	ActiveFilePath      string   `json:"activeFilePath,omitempty"`
	Selection           string   `json:"selection,omitempty"`
	LatestTerminalError string   `json:"latestTerminalError,omitempty"`
	ChangedFiles        []string `json:"changedFiles,omitempty"`
	LastRunProfile      string   `json:"lastRunProfile,omitempty"`
	LastRunStatus       string   `json:"lastRunStatus,omitempty"`
}

type SubmitTaskInput struct {
	Prompt         string           `json:"prompt"`
	Template       string           `json:"template,omitempty"`
	Model          string           `json:"model,omitempty"`
	ReasoningLevel string           `json:"reasoningLevel,omitempty"`
	Context        WorkspaceContext `json:"context"`
}

type ProviderVisibleEvent struct {
	Kind  string         `json:"kind,omitempty"`
	Role  string         `json:"role,omitempty"`
	Title string         `json:"title,omitempty"`
	Body  string         `json:"body,omitempty"`
	Data  map[string]any `json:"data,omitempty"`
}

type TaskHandle struct {
	TaskID         string                 `json:"taskId"`
	ProviderEvents []ProviderVisibleEvent `json:"providerEvents,omitempty"`
}

type ApplyPatchInput struct {
	TaskID   string                  `json:"taskId"`
	Mode     string                  `json:"mode"`
	Selected []protocol.SelectedHunk `json:"selected,omitempty"`
}

type ApplyPatchResult struct {
	Status  string `json:"status"`
	Message string `json:"message"`
}

type RunProfileInput struct {
	TaskID    string `json:"taskId"`
	JobID     string `json:"jobId"`
	ProfileID string `json:"profileId"`
	Command   string `json:"command"`
}

type RunHandle struct {
	RunID string `json:"runId"`
}

type RunResult struct {
	RunID          string                 `json:"runId"`
	ProfileID      string                 `json:"profileId"`
	Status         string                 `json:"status"`
	Summary        string                 `json:"summary"`
	TopErrors      []protocol.ParsedError `json:"topErrors,omitempty"`
	Excerpt        string                 `json:"excerpt,omitempty"`
	Output         string                 `json:"output,omitempty"`
	ChangedFiles   []string               `json:"changedFiles,omitempty"`
	ProviderEvents []ProviderVisibleEvent `json:"providerEvents,omitempty"`
}

type OpenLocationInput struct {
	Path   string `json:"path"`
	Line   int    `json:"line"`
	Column int    `json:"column,omitempty"`
}

type RunProfileDescriptor struct {
	ID       string `json:"id"`
	Label    string `json:"label"`
	Command  string `json:"command"`
	Scope    string `json:"scope"`
	Optional bool   `json:"optional,omitempty"`
}

type WorkspaceAdapter interface {
	Name() string
	Capabilities() AdapterCapabilities
	GetContext(ctx context.Context, input ContextRequest) (WorkspaceContext, error)
	SubmitTask(ctx context.Context, input SubmitTaskInput) (TaskHandle, error)
	GetPatch(ctx context.Context, taskID string) (*protocol.PatchReadyPayload, error)
	ApplyPatch(ctx context.Context, input ApplyPatchInput) (ApplyPatchResult, error)
	RunProfile(ctx context.Context, input RunProfileInput) (RunHandle, error)
	GetRunResult(ctx context.Context, runID string) (*RunResult, error)
	OpenLocation(ctx context.Context, input OpenLocationInput) error
}

type Job struct {
	ID         string
	ThreadID   string
	SessionID  string
	TaskID     string
	Prompt     string
	State      string
	PatchFiles []string
	CreatedAt  time.Time
}
