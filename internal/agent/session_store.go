package agent

import (
	"sort"
	"strings"
	"sync"

	"github.com/Fharena/VibeDeck/internal/protocol"
)

type SharedSessionSummary struct {
	ID               string `json:"id"`
	ThreadID         string `json:"threadId"`
	ControlSessionID string `json:"controlSessionId,omitempty"`
	Title            string `json:"title"`
	Provider         string `json:"provider,omitempty"`
	WorkspaceRoot    string `json:"workspaceRoot,omitempty"`
	CurrentJobID     string `json:"currentJobId,omitempty"`
	Phase            string `json:"phase,omitempty"`
	LastEventKind    string `json:"lastEventKind,omitempty"`
	LastEventText    string `json:"lastEventText,omitempty"`
	UpdatedAt        int64  `json:"updatedAt"`
}

type SharedSessionDetail struct {
	Session        SharedSessionSummary  `json:"session"`
	LiveState      SessionLiveState      `json:"liveState"`
	OperationState SessionOperationState `json:"operationState"`
	Timeline       []ThreadEvent         `json:"timeline"`
}

type SessionLiveState struct {
	Participants []SessionParticipant  `json:"participants,omitempty"`
	Composer     SessionComposerState  `json:"composer"`
	Focus        SessionFocusState     `json:"focus"`
	Activity     SessionActivityState  `json:"activity"`
	Reasoning    SessionReasoningState `json:"reasoning"`
	Plan         SessionPlanState      `json:"plan"`
	Tools        SessionToolState      `json:"tools"`
	Terminal     SessionTerminalState  `json:"terminal"`
	Workspace    SessionWorkspaceState `json:"workspace"`
}

type SessionParticipant struct {
	ParticipantID string `json:"participantId"`
	ClientType    string `json:"clientType,omitempty"`
	DisplayName   string `json:"displayName,omitempty"`
	Active        bool   `json:"active"`
	LastSeenAt    int64  `json:"lastSeenAt,omitempty"`
}

type SessionComposerState struct {
	DraftText string `json:"draftText,omitempty"`
	IsTyping  bool   `json:"isTyping"`
	UpdatedAt int64  `json:"updatedAt,omitempty"`
}

type SessionFocusState struct {
	ActiveFilePath string `json:"activeFilePath,omitempty"`
	Selection      string `json:"selection,omitempty"`
	PatchPath      string `json:"patchPath,omitempty"`
	RunErrorPath   string `json:"runErrorPath,omitempty"`
	RunErrorLine   int    `json:"runErrorLine,omitempty"`
	UpdatedAt      int64  `json:"updatedAt,omitempty"`
}

type SessionActivityState struct {
	Phase     string `json:"phase,omitempty"`
	Summary   string `json:"summary,omitempty"`
	UpdatedAt int64  `json:"updatedAt,omitempty"`
}

type SessionReasoningState struct {
	Title      string `json:"title,omitempty"`
	Summary    string `json:"summary,omitempty"`
	SourceKind string `json:"sourceKind,omitempty"`
	UpdatedAt  int64  `json:"updatedAt,omitempty"`
}

type SessionPlanState struct {
	Summary   string            `json:"summary,omitempty"`
	Items     []SessionPlanItem `json:"items,omitempty"`
	UpdatedAt int64             `json:"updatedAt,omitempty"`
}

type SessionPlanItem struct {
	ID        string `json:"id,omitempty"`
	Label     string `json:"label,omitempty"`
	Status    string `json:"status,omitempty"`
	Detail    string `json:"detail,omitempty"`
	UpdatedAt int64  `json:"updatedAt,omitempty"`
}

type SessionToolState struct {
	CurrentLabel  string                `json:"currentLabel,omitempty"`
	CurrentStatus string                `json:"currentStatus,omitempty"`
	Activities    []SessionToolActivity `json:"activities,omitempty"`
	UpdatedAt     int64                 `json:"updatedAt,omitempty"`
}

type SessionToolActivity struct {
	Kind   string `json:"kind,omitempty"`
	Label  string `json:"label,omitempty"`
	Status string `json:"status,omitempty"`
	Detail string `json:"detail,omitempty"`
	At     int64  `json:"at,omitempty"`
}

type SessionTerminalState struct {
	Status    string `json:"status,omitempty"`
	ProfileID string `json:"profileId,omitempty"`
	Label     string `json:"label,omitempty"`
	Command   string `json:"command,omitempty"`
	Summary   string `json:"summary,omitempty"`
	Excerpt   string `json:"excerpt,omitempty"`
	Output    string `json:"output,omitempty"`
	UpdatedAt int64  `json:"updatedAt,omitempty"`
}

type SessionWorkspaceState struct {
	RootPath       string   `json:"rootPath,omitempty"`
	ActiveFilePath string   `json:"activeFilePath,omitempty"`
	PatchFiles     []string `json:"patchFiles,omitempty"`
	ChangedFiles   []string `json:"changedFiles,omitempty"`
	UpdatedAt      int64    `json:"updatedAt,omitempty"`
}

type SessionRunError struct {
	Path    string `json:"path,omitempty"`
	Line    int    `json:"line,omitempty"`
	Message string `json:"message,omitempty"`
}

type SessionOperationState struct {
	CurrentJobID       string            `json:"currentJobId,omitempty"`
	Phase              string            `json:"phase,omitempty"`
	PatchSummary       string            `json:"patchSummary,omitempty"`
	PatchFileCount     int               `json:"patchFileCount,omitempty"`
	PatchFiles         []string          `json:"patchFiles,omitempty"`
	PatchResultStatus  string            `json:"patchResultStatus,omitempty"`
	PatchResultMessage string            `json:"patchResultMessage,omitempty"`
	RunProfileID       string            `json:"runProfileId,omitempty"`
	RunLabel           string            `json:"runLabel,omitempty"`
	RunCommand         string            `json:"runCommand,omitempty"`
	RunStatus          string            `json:"runStatus,omitempty"`
	RunSummary         string            `json:"runSummary,omitempty"`
	RunExcerpt         string            `json:"runExcerpt,omitempty"`
	RunOutput          string            `json:"runOutput,omitempty"`
	RunChangedFiles    []string          `json:"runChangedFiles,omitempty"`
	RunTopErrors       []SessionRunError `json:"runTopErrors,omitempty"`
	CurrentJobFiles    []string          `json:"currentJobFiles,omitempty"`
	LastError          string            `json:"lastError,omitempty"`
}

type SessionStore struct {
	threadStore   *ThreadStore
	workspaceRoot string
	provider      string

	mu                    sync.RWMutex
	participantsBySession map[string]map[string]SessionParticipant
	composerBySession     map[string]SessionComposerState
	focusBySession        map[string]SessionFocusState
	activityBySession     map[string]SessionActivityState
	reasoningBySession    map[string]SessionReasoningState
	planBySession         map[string]SessionPlanState
	toolsBySession        map[string]SessionToolState
	terminalBySession     map[string]SessionTerminalState
	workspaceBySession    map[string]SessionWorkspaceState
}

func NewSessionStore(threadStore *ThreadStore, adapterInfo AdapterRuntimeInfo) *SessionStore {
	return &SessionStore{
		threadStore:           threadStore,
		workspaceRoot:         strings.TrimSpace(adapterInfo.WorkspaceRoot),
		provider:              inferProviderName(adapterInfo),
		participantsBySession: make(map[string]map[string]SessionParticipant),
		composerBySession:     make(map[string]SessionComposerState),
		focusBySession:        make(map[string]SessionFocusState),
		activityBySession:     make(map[string]SessionActivityState),
		reasoningBySession:    make(map[string]SessionReasoningState),
		planBySession:         make(map[string]SessionPlanState),
		toolsBySession:        make(map[string]SessionToolState),
		terminalBySession:     make(map[string]SessionTerminalState),
		workspaceBySession:    make(map[string]SessionWorkspaceState),
	}
}

func (s *SessionStore) CurrentSessionID() string {
	sessions := s.List()
	if len(sessions) == 0 {
		return ""
	}
	return sessions[0].ID
}

func (s *SessionStore) List() []SharedSessionSummary {
	if s == nil || s.threadStore == nil {
		return nil
	}

	threads := s.threadStore.List()
	sessions := make([]SharedSessionSummary, 0, len(threads))
	for _, thread := range threads {
		sessions = append(sessions, SharedSessionSummary{
			ID:               thread.ID,
			ThreadID:         thread.ID,
			ControlSessionID: thread.SessionID,
			Title:            thread.Title,
			Provider:         s.provider,
			WorkspaceRoot:    s.workspaceRoot,
			CurrentJobID:     thread.CurrentJobID,
			Phase:            phaseFromThreadSummary(thread),
			LastEventKind:    thread.LastEventKind,
			LastEventText:    thread.LastEventText,
			UpdatedAt:        thread.UpdatedAt,
		})
	}
	return sessions
}

func (s *SessionStore) Get(sessionID string) (SharedSessionDetail, bool) {
	if s == nil || s.threadStore == nil {
		return SharedSessionDetail{}, false
	}

	detail, ok := s.threadStore.Get(strings.TrimSpace(sessionID))
	if !ok {
		return SharedSessionDetail{}, false
	}

	operation := deriveSessionOperationState(detail)
	live := deriveSessionLiveState(detail, operation, s.workspaceRoot)
	live = s.applyLiveOverrides(detail.Thread.ID, live)

	return SharedSessionDetail{
		Session: SharedSessionSummary{
			ID:               detail.Thread.ID,
			ThreadID:         detail.Thread.ID,
			ControlSessionID: detail.Thread.SessionID,
			Title:            detail.Thread.Title,
			Provider:         s.provider,
			WorkspaceRoot:    s.workspaceRoot,
			CurrentJobID:     operation.CurrentJobID,
			Phase:            operation.Phase,
			LastEventKind:    detail.Thread.LastEventKind,
			LastEventText:    detail.Thread.LastEventText,
			UpdatedAt:        detail.Thread.UpdatedAt,
		},
		LiveState:      live,
		OperationState: operation,
		Timeline:       detail.Events,
	}, true
}

func (s *SessionStore) UpsertParticipant(sessionID string, participant SessionParticipant) {
	if s == nil {
		return
	}
	participant.ParticipantID = strings.TrimSpace(participant.ParticipantID)
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" || participant.ParticipantID == "" {
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	participants := s.participantsBySession[sessionID]
	if participants == nil {
		participants = make(map[string]SessionParticipant)
		s.participantsBySession[sessionID] = participants
	}
	participants[participant.ParticipantID] = participant
}

func (s *SessionStore) UpdateComposer(sessionID string, composer SessionComposerState) {
	if s == nil {
		return
	}
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.composerBySession[sessionID] = composer
}

func (s *SessionStore) UpdateFocus(sessionID string, focus SessionFocusState) {
	if s == nil {
		return
	}
	sessionID = strings.TrimSpace(sessionID)
	if sessionID == "" {
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.focusBySession[sessionID] = focus
}

func (s *SessionStore) applyLiveOverrides(sessionID string, base SessionLiveState) SessionLiveState {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if participants := s.participantsBySession[sessionID]; len(participants) > 0 {
		base.Participants = participantsSlice(participants)
	}
	if composer, ok := s.composerBySession[sessionID]; ok {
		base.Composer = composer
	}
	if focus, ok := s.focusBySession[sessionID]; ok {
		base.Focus = focus
	}
	if activity, ok := s.activityBySession[sessionID]; ok {
		base.Activity = activity
	}
	if reasoning, ok := s.reasoningBySession[sessionID]; ok {
		base.Reasoning = reasoning
	}
	if plan, ok := s.planBySession[sessionID]; ok {
		base.Plan = plan
	}
	if tools, ok := s.toolsBySession[sessionID]; ok {
		base.Tools = tools
	}
	if terminal, ok := s.terminalBySession[sessionID]; ok {
		base.Terminal = terminal
	}
	if workspace, ok := s.workspaceBySession[sessionID]; ok {
		base.Workspace = workspace
	}
	return base
}

func participantsSlice(items map[string]SessionParticipant) []SessionParticipant {
	out := make([]SessionParticipant, 0, len(items))
	for _, participant := range items {
		out = append(out, participant)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].LastSeenAt == out[j].LastSeenAt {
			return out[i].ParticipantID < out[j].ParticipantID
		}
		return out[i].LastSeenAt > out[j].LastSeenAt
	})
	return out
}

func deriveSessionOperationState(detail ThreadDetail) SessionOperationState {
	operation := SessionOperationState{
		CurrentJobID: detail.Thread.CurrentJobID,
		Phase:        phaseFromThreadSummary(detail.Thread),
	}

	for _, event := range detail.Events {
		if event.JobID != "" {
			operation.CurrentJobID = event.JobID
		}

		switch event.Kind {
		case "prompt_submitted", "prompt_accepted":
			operation.Phase = "prompting"
		case "patch_ready":
			operation.Phase = "reviewing"
			operation.PatchSummary = firstNonEmptyText(stringValue(event.Data["summary"]), event.Body)
			operation.PatchFiles = patchPathsFromAny(event.Data["files"])
			operation.PatchFileCount = len(operation.PatchFiles)
			if len(operation.PatchFiles) > 0 {
				operation.CurrentJobFiles = cloneStrings(operation.PatchFiles)
			}
		case "patch_apply_requested":
			operation.Phase = "applying"
		case "patch_applied":
			operation.PatchResultStatus = valueFromData(event.Data, "status", operation.PatchResultStatus)
			operation.PatchResultMessage = firstNonEmptyText(valueFromData(event.Data, "message", ""), event.Body)
			if strings.EqualFold(operation.PatchResultStatus, "failed") {
				operation.Phase = "waiting_input"
				operation.LastError = firstNonEmptyText(operation.PatchResultMessage, operation.LastError)
			} else {
				operation.Phase = "applied"
			}
		case "run_requested":
			operation.Phase = "running"
			operation.RunProfileID = valueFromData(event.Data, "profileId", operation.RunProfileID)
			operation.RunLabel = firstNonEmptyText(valueFromData(event.Data, "label", ""), event.Body, operation.RunLabel)
			operation.RunCommand = valueFromData(event.Data, "command", operation.RunCommand)
		case "run_finished":
			operation.Phase = "waiting_input"
			operation.RunProfileID = valueFromData(event.Data, "profileId", operation.RunProfileID)
			operation.RunStatus = valueFromData(event.Data, "status", operation.RunStatus)
			operation.RunSummary = firstNonEmptyText(valueFromData(event.Data, "summary", ""), event.Body)
			operation.RunExcerpt = firstNonEmptyText(valueFromData(event.Data, "excerpt", ""), operation.RunExcerpt)
			operation.RunOutput = firstNonEmptyText(valueFromData(event.Data, "output", ""), operation.RunOutput)
			if operation.RunOutput == "" {
				operation.RunOutput = operation.RunExcerpt
			}
			changedFiles := stringSliceFromAny(event.Data["changedFiles"])
			if len(changedFiles) > 0 {
				operation.RunChangedFiles = changedFiles
				operation.CurrentJobFiles = cloneStrings(changedFiles)
			}
			operation.RunTopErrors = sessionRunErrorsFromAny(event.Data["topErrors"])
			if strings.EqualFold(operation.RunStatus, "failed") {
				operation.LastError = firstNonEmptyText(operation.RunSummary, firstParsedErrorMessage(event.Data["topErrors"]))
			}
		}
	}

	if operation.PatchFileCount == 0 && len(operation.PatchFiles) > 0 {
		operation.PatchFileCount = len(operation.PatchFiles)
	}
	if len(operation.CurrentJobFiles) == 0 {
		operation.CurrentJobFiles = firstNonEmptyStrings(operation.RunChangedFiles, operation.PatchFiles)
	}
	if operation.Phase == "" {
		operation.Phase = "idle"
	}
	return operation
}

func deriveSessionLiveState(detail ThreadDetail, operation SessionOperationState, workspaceRoot string) SessionLiveState {
	live := SessionLiveState{
		Reasoning: deriveSessionReasoningState(detail, operation),
		Plan:      deriveSessionPlanState(detail, operation),
		Tools:     deriveSessionToolState(detail),
		Terminal:  deriveSessionTerminalState(detail, operation),
		Workspace: deriveSessionWorkspaceState(detail, operation, workspaceRoot),
	}
	for _, event := range detail.Events {
		switch event.Kind {
		case "prompt_submitted":
			live.Composer = SessionComposerState{
				DraftText: event.Body,
				UpdatedAt: event.At,
			}
			live.Focus.ActiveFilePath = stringValue(event.Data["activeFilePath"])
			live.Focus.Selection = stringValue(event.Data["selection"])
			live.Focus.UpdatedAt = event.At
		case "patch_ready":
			paths := patchPathsFromAny(event.Data["files"])
			if len(paths) > 0 {
				live.Focus.PatchPath = paths[0]
				live.Focus.UpdatedAt = event.At
			}
		case "run_finished":
			path, line, _ := firstParsedError(event.Data["topErrors"])
			if path != "" {
				live.Focus.RunErrorPath = path
				live.Focus.RunErrorLine = line
				live.Focus.UpdatedAt = event.At
			}
		}
	}

	if len(detail.Events) > 0 {
		last := detail.Events[len(detail.Events)-1]
		live.Activity = SessionActivityState{
			Phase:     operation.Phase,
			Summary:   firstNonEmptyText(last.Body, last.Title),
			UpdatedAt: last.At,
		}
	} else {
		live.Activity.Phase = operation.Phase
	}

	if live.Workspace.ActiveFilePath == "" {
		live.Workspace.ActiveFilePath = firstNonEmptyText(live.Focus.ActiveFilePath, firstString(live.Workspace.PatchFiles), firstString(live.Workspace.ChangedFiles))
	}
	if live.Focus.ActiveFilePath == "" && live.Workspace.ActiveFilePath != "" {
		live.Focus.ActiveFilePath = live.Workspace.ActiveFilePath
		live.Focus.UpdatedAt = firstNonZero(live.Focus.UpdatedAt, live.Workspace.UpdatedAt)
	}
	if len(live.Workspace.PatchFiles) == 0 && live.Focus.PatchPath != "" {
		live.Workspace.PatchFiles = []string{live.Focus.PatchPath}
	}
	if live.Workspace.UpdatedAt == 0 {
		live.Workspace.UpdatedAt = firstNonZero(live.Focus.UpdatedAt, live.Activity.UpdatedAt, detail.Thread.UpdatedAt)
	}

	return live
}

func deriveSessionReasoningState(detail ThreadDetail, operation SessionOperationState) SessionReasoningState {
	for i := len(detail.Events) - 1; i >= 0; i-- {
		event := detail.Events[i]
		if event.Role != "assistant" && event.Role != "system" {
			continue
		}
		if event.Role == "system" && event.Kind == "tool_activity" && valueFromData(event.Data, "summary", "") == "" {
			continue
		}
		summary := firstNonEmptyText(valueFromData(event.Data, "summary", ""), event.Body, event.Title)
		if summary == "" {
			continue
		}
		return SessionReasoningState{
			Title:      firstNonEmptyText(event.Title, sessionEventLabel(event.Kind)),
			Summary:    summary,
			SourceKind: event.Kind,
			UpdatedAt:  event.At,
		}
	}
	if operation.Phase == "" {
		return SessionReasoningState{}
	}
	return SessionReasoningState{
		Title:     sessionPhaseLabel(operation.Phase),
		Summary:   sessionPlanSummary(nil, operation.Phase),
		UpdatedAt: detail.Thread.UpdatedAt,
	}
}

func deriveSessionPlanState(detail ThreadDetail, operation SessionOperationState) SessionPlanState {
	var promptAt int64
	var patchAt int64
	var patchSummary string
	var applyRequestedAt int64
	var applyAt int64
	var applyStatus string
	var applyDetail string
	var runRequestedAt int64
	var runAt int64
	var runStatus string
	var runDetail string

	for _, event := range detail.Events {
		switch event.Kind {
		case "prompt_submitted":
			if promptAt == 0 {
				promptAt = event.At
			}
		case "patch_ready":
			patchAt = event.At
			patchSummary = firstNonEmptyText(valueFromData(event.Data, "summary", ""), event.Body)
		case "patch_apply_requested":
			applyRequestedAt = event.At
		case "patch_applied":
			applyAt = event.At
			applyStatus = valueFromData(event.Data, "status", applyStatus)
			applyDetail = firstNonEmptyText(valueFromData(event.Data, "message", ""), event.Body)
		case "run_requested":
			runRequestedAt = event.At
		case "run_finished":
			runAt = event.At
			runStatus = valueFromData(event.Data, "status", runStatus)
			runDetail = firstNonEmptyText(valueFromData(event.Data, "summary", ""), event.Body)
		}
	}

	contextPlan := deriveContextPlanState(detail.Events)
	if len(contextPlan.Items) > 0 &&
		patchAt == 0 &&
		applyRequestedAt == 0 &&
		applyAt == 0 &&
		runRequestedAt == 0 &&
		runAt == 0 {
		contextPlan.UpdatedAt = firstNonZero(contextPlan.UpdatedAt, promptAt, detail.Thread.UpdatedAt)
		return contextPlan
	}

	items := []SessionPlanItem{
		{ID: "request", Label: "요청 접수", Status: statusFromPresence(promptAt > 0, false), Detail: "사용자 요청이 세션에 기록되었습니다.", UpdatedAt: promptAt},
		{ID: "draft_patch", Label: "패치 초안 준비", Status: planStatus(patchAt > 0, promptAt > 0 && patchAt == 0, false), Detail: firstNonEmptyText(patchSummary, sessionPlanDetail("draft_patch", operation.Phase)), UpdatedAt: firstNonZero(patchAt, promptAt)},
		{ID: "apply_patch", Label: "패치 적용", Status: planStatus(applyAt > 0 && !strings.EqualFold(applyStatus, "failed"), applyRequestedAt > 0 && applyAt == 0, strings.EqualFold(applyStatus, "failed")), Detail: firstNonEmptyText(applyDetail, sessionPlanDetail("apply_patch", operation.Phase)), UpdatedAt: firstNonZero(applyAt, applyRequestedAt)},
		{ID: "verify_run", Label: "실행 검증", Status: planStatus(runAt > 0 && !strings.EqualFold(runStatus, "failed"), runRequestedAt > 0 && runAt == 0, strings.EqualFold(runStatus, "failed")), Detail: firstNonEmptyText(runDetail, sessionPlanDetail("verify_run", operation.Phase)), UpdatedAt: firstNonZero(runAt, runRequestedAt)},
	}

	return SessionPlanState{Summary: sessionPlanSummary(items, operation.Phase), Items: items, UpdatedAt: firstNonZero(runAt, applyAt, patchAt, promptAt, detail.Thread.UpdatedAt)}
}

func deriveSessionToolState(detail ThreadDetail) SessionToolState {
	activities := make([]SessionToolActivity, 0, len(detail.Events))
	for _, event := range detail.Events {
		activity, ok := sessionToolActivityFromEvent(event)
		if !ok {
			continue
		}
		activities = append(activities, activity)
	}
	if len(activities) == 0 {
		return SessionToolState{}
	}
	if len(activities) > 8 {
		activities = append([]SessionToolActivity(nil), activities[len(activities)-8:]...)
	}
	current := activities[len(activities)-1]
	return SessionToolState{CurrentLabel: current.Label, CurrentStatus: current.Status, Activities: activities, UpdatedAt: current.At}
}

func deriveSessionTerminalState(detail ThreadDetail, operation SessionOperationState) SessionTerminalState {
	terminal := SessionTerminalState{Status: operation.RunStatus, ProfileID: operation.RunProfileID, Label: firstNonEmptyText(operation.RunLabel, operation.RunProfileID), Command: operation.RunCommand, Summary: operation.RunSummary, Excerpt: operation.RunExcerpt, Output: operation.RunOutput}
	for _, event := range detail.Events {
		switch event.Kind {
		case "run_requested":
			terminal.Status = "running"
			terminal.ProfileID = valueFromData(event.Data, "profileId", terminal.ProfileID)
			terminal.Label = firstNonEmptyText(valueFromData(event.Data, "label", ""), event.Body, terminal.Label)
			terminal.Command = valueFromData(event.Data, "command", terminal.Command)
			terminal.UpdatedAt = event.At
		case "run_finished":
			terminal.Status = firstNonEmptyText(valueFromData(event.Data, "status", ""), terminal.Status)
			terminal.ProfileID = valueFromData(event.Data, "profileId", terminal.ProfileID)
			terminal.Summary = firstNonEmptyText(valueFromData(event.Data, "summary", ""), event.Body, terminal.Summary)
			terminal.Excerpt = firstNonEmptyText(valueFromData(event.Data, "excerpt", ""), terminal.Excerpt)
			terminal.Output = firstNonEmptyText(valueFromData(event.Data, "output", ""), terminal.Output)
			if terminal.Output == "" {
				terminal.Output = terminal.Excerpt
			}
			terminal.UpdatedAt = event.At
		}
	}
	if terminal.UpdatedAt == 0 {
		for i := len(detail.Events) - 1; i >= 0; i-- {
			event := detail.Events[i]
			if event.Kind != "tool_activity" {
				continue
			}
			commands := sessionContextCommands(event.Data)
			terminalFiles := sessionContextTerminalFiles(event.Data)
			if len(commands) == 0 && len(terminalFiles) == 0 {
				continue
			}
			excerpt := firstNonEmptyText(event.Body, strings.Join(firstNonEmptyStrings(commands, terminalFiles), " | "))
			terminal = SessionTerminalState{
				Status:    "context",
				Label:     firstNonEmptyText(valueFromData(event.Data, "label", ""), "Cursor 터미널 맥락"),
				Command:   firstString(commands),
				Summary:   firstNonEmptyText(event.Body, "Cursor가 최근 터미널 맥락을 공유했습니다."),
				Excerpt:   excerpt,
				Output:    excerpt,
				UpdatedAt: event.At,
			}
			break
		}
	}
	return terminal
}

func deriveSessionWorkspaceState(detail ThreadDetail, operation SessionOperationState, workspaceRoot string) SessionWorkspaceState {
	workspace := SessionWorkspaceState{RootPath: strings.TrimSpace(workspaceRoot)}
	for _, event := range detail.Events {
		switch event.Kind {
		case "prompt_submitted":
			path := stringValue(event.Data["activeFilePath"])
			if path != "" {
				workspace.ActiveFilePath = path
				workspace.UpdatedAt = event.At
			}
			changedFiles := stringSliceFromAny(event.Data["changedFiles"])
			if len(changedFiles) > 0 {
				workspace.ChangedFiles = changedFiles
				workspace.UpdatedAt = event.At
			}
		case "patch_ready":
			patchFiles := patchPathsFromAny(event.Data["files"])
			if len(patchFiles) > 0 {
				workspace.PatchFiles = patchFiles
				workspace.UpdatedAt = event.At
			}
		case "run_finished":
			changedFiles := stringSliceFromAny(event.Data["changedFiles"])
			if len(changedFiles) > 0 {
				workspace.ChangedFiles = changedFiles
				workspace.UpdatedAt = event.At
			}
		}
	}
	if len(workspace.PatchFiles) == 0 && len(operation.PatchFiles) > 0 {
		workspace.PatchFiles = cloneStrings(operation.PatchFiles)
	}
	if len(workspace.ChangedFiles) == 0 && len(operation.RunChangedFiles) > 0 {
		workspace.ChangedFiles = cloneStrings(operation.RunChangedFiles)
	}
	if workspace.ActiveFilePath == "" {
		workspace.ActiveFilePath = firstNonEmptyText(firstString(operation.PatchFiles), firstString(operation.RunChangedFiles), firstString(operation.CurrentJobFiles))
	}
	if workspace.ActiveFilePath == "" {
		for i := len(detail.Events) - 1; i >= 0; i-- {
			event := detail.Events[i]
			if event.Kind != "tool_activity" {
				continue
			}
			contextFiles := sessionContextFiles(event.Data)
			if len(contextFiles) == 0 {
				continue
			}
			workspace.ActiveFilePath = firstString(contextFiles)
			workspace.UpdatedAt = firstNonZero(workspace.UpdatedAt, event.At)
			break
		}
	}
	if workspace.UpdatedAt == 0 {
		workspace.UpdatedAt = detail.Thread.UpdatedAt
	}
	return workspace
}

func sessionToolActivityFromEvent(event ThreadEvent) (SessionToolActivity, bool) {
	activity := SessionToolActivity{Kind: event.Kind, At: event.At}
	switch event.Kind {
	case "prompt_submitted":
		activity.Label = "프롬프트 전송"
		activity.Status = "completed"
		activity.Detail = firstNonEmptyText(event.Body, event.Title)
	case "prompt_accepted":
		activity.Label = "에이전트 시작"
		activity.Status = "completed"
		activity.Detail = firstNonEmptyText(event.Body, event.Title)
	case "patch_ready":
		activity.Label = "패치 준비"
		activity.Status = "completed"
		activity.Detail = firstNonEmptyText(valueFromData(event.Data, "summary", ""), event.Body)
	case "patch_apply_requested":
		activity.Label = "패치 적용"
		activity.Status = "in_progress"
		activity.Detail = firstNonEmptyText(event.Body, event.Title)
	case "patch_applied":
		activity.Label = "패치 적용"
		if strings.EqualFold(valueFromData(event.Data, "status", ""), "failed") {
			activity.Status = "failed"
		} else {
			activity.Status = "completed"
		}
		activity.Detail = firstNonEmptyText(valueFromData(event.Data, "message", ""), event.Body)
	case "run_requested":
		activity.Label = "명령 실행"
		activity.Status = "in_progress"
		activity.Detail = firstNonEmptyText(valueFromData(event.Data, "command", ""), valueFromData(event.Data, "label", ""), event.Body)
	case "run_finished":
		activity.Label = "명령 실행"
		if strings.EqualFold(valueFromData(event.Data, "status", ""), "failed") {
			activity.Status = "failed"
		} else {
			activity.Status = "completed"
		}
		activity.Detail = firstNonEmptyText(valueFromData(event.Data, "summary", ""), event.Body)
	case "tool_activity":
		activity.Label = firstNonEmptyText(sessionToolActivityLabel(event), "작업 맥락")
		activity.Status = firstNonEmptyText(normalizeSessionStatus(valueFromData(event.Data, "status", "")), "completed")
		activity.Detail = firstNonEmptyText(event.Body, sessionToolActivityDetail(event))
	default:
		return SessionToolActivity{}, false
	}
	return activity, true
}

func deriveContextPlanState(events []ThreadEvent) SessionPlanState {
	for i := len(events) - 1; i >= 0; i-- {
		event := events[i]
		if event.Kind != "tool_activity" {
			continue
		}
		items := sessionPlanItemsFromAny(event.Data["todos"], event.At)
		if len(items) == 0 {
			continue
		}
		return SessionPlanState{
			Summary:   contextPlanSummary(items),
			Items:     items,
			UpdatedAt: event.At,
		}
	}
	return SessionPlanState{}
}

func contextPlanSummary(items []SessionPlanItem) string {
	for _, item := range items {
		if item.Status == "failed" {
			return item.Label + " 단계에서 확인이 필요합니다."
		}
	}
	for _, item := range items {
		if item.Status == "in_progress" {
			return item.Label + " 진행 중입니다."
		}
	}
	if len(items) > 0 {
		return "Cursor 작업 계획을 공유하고 있습니다."
	}
	return ""
}

func sessionToolActivityLabel(event ThreadEvent) string {
	if event.Kind != "tool_activity" {
		return strings.TrimSpace(event.Title)
	}
	if len(sessionPlanItemsFromAny(event.Data["todos"], event.At)) > 0 {
		return "작업 계획"
	}
	if len(sessionContextCommands(event.Data)) > 0 || len(sessionContextTerminalFiles(event.Data)) > 0 {
		return "터미널 맥락"
	}
	if len(sessionContextFiles(event.Data)) > 0 {
		return "파일 맥락"
	}
	return firstNonEmptyText(event.Title, valueFromData(event.Data, "label", ""), "작업 맥락")
}

func sessionToolActivityDetail(event ThreadEvent) string {
	return firstNonEmptyText(
		valueFromData(event.Data, "summary", ""),
		event.Body,
		firstString(firstNonEmptyStrings(sessionContextCommands(event.Data), sessionContextFiles(event.Data))),
	)
}

func sessionPlanItemsFromAny(value any, fallbackAt int64) []SessionPlanItem {
	typed, ok := value.([]any)
	if !ok {
		return nil
	}

	items := make([]SessionPlanItem, 0, len(typed))
	for index, raw := range typed {
		switch item := raw.(type) {
		case string:
			label := strings.TrimSpace(item)
			if label == "" {
				continue
			}
			items = append(items, SessionPlanItem{
				ID:        label,
				Label:     label,
				Status:    "pending",
				UpdatedAt: fallbackAt,
			})
		case map[string]any:
			label := firstNonEmptyText(
				stringValue(item["label"]),
				stringValue(item["title"]),
				stringValue(item["text"]),
				stringValue(item["detail"]),
			)
			if label == "" {
				continue
			}
			status := normalizeSessionStatus(stringValue(item["status"]))
			if status == "" {
				switch {
				case boolValue(item["completed"]) || boolValue(item["done"]):
					status = "completed"
				case boolValue(item["active"]) || boolValue(item["current"]) || boolValue(item["inProgress"]):
					status = "in_progress"
				default:
					status = "pending"
				}
			}
			items = append(items, SessionPlanItem{
				ID:        firstNonEmptyText(stringValue(item["id"]), label),
				Label:     label,
				Status:    status,
				Detail:    firstNonEmptyText(stringValue(item["detail"]), stringValue(item["description"]), stringValue(item["text"])),
				UpdatedAt: firstNonZero(int64(intValue(item["updatedAt"])), fallbackAt, int64(index+1)),
			})
		}
	}
	return items
}

func normalizeSessionStatus(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "completed", "complete", "done", "success":
		return "completed"
	case "in_progress", "in-progress", "running", "active", "doing":
		return "in_progress"
	case "failed", "error", "blocked":
		if strings.EqualFold(strings.TrimSpace(value), "blocked") {
			return "blocked"
		}
		return "failed"
	case "pending", "todo", "queued":
		return "pending"
	default:
		return strings.TrimSpace(value)
	}
}

func boolValue(value any) bool {
	typed, ok := value.(bool)
	return ok && typed
}

func sessionContextFiles(data map[string]any) []string {
	return stringsFromMapFields(
		data,
		"files",
		"filePaths",
		"selectedFiles",
		"selectedFilePaths",
		"attachedFiles",
		"mentionedFiles",
		"folderSelections",
	)
}

func sessionContextCommands(data map[string]any) []string {
	return stringsFromMapFields(data, "terminalCommands", "commands", "command")
}

func sessionContextTerminalFiles(data map[string]any) []string {
	return stringsFromMapFields(data, "terminalFiles")
}

func stringsFromMapFields(data map[string]any, fields ...string) []string {
	if data == nil {
		return nil
	}
	out := make([]string, 0, len(fields))
	for _, field := range fields {
		out = append(out, flattenUnknownStrings(data[field])...)
	}
	return dedupeStrings(out)
}

func flattenUnknownStrings(value any) []string {
	switch typed := value.(type) {
	case string:
		text := strings.TrimSpace(typed)
		if text == "" {
			return nil
		}
		return []string{text}
	case []string:
		return cloneStrings(typed)
	case []any:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			out = append(out, flattenUnknownStrings(item)...)
		}
		return dedupeStrings(out)
	case map[string]any:
		out := make([]string, 0, 6)
		for _, key := range []string{"path", "filePath", "command", "label", "text", "title", "value"} {
			out = append(out, flattenUnknownStrings(typed[key])...)
		}
		return dedupeStrings(out)
	default:
		return nil
	}
}

func sessionPhaseLabel(phase string) string {
	switch strings.TrimSpace(phase) {
	case "prompting":
		return "요청 분석"
	case "reviewing":
		return "패치 검토"
	case "applying":
		return "패치 적용"
	case "applied":
		return "적용 완료"
	case "running":
		return "실행 검증"
	case "waiting_input":
		return "다음 입력 대기"
	default:
		return "세션 상태"
	}
}

func sessionEventLabel(kind string) string {
	switch strings.TrimSpace(kind) {
	case "prompt_submitted":
		return "프롬프트 제출"
	case "prompt_accepted":
		return "작업 시작"
	case "patch_ready":
		return "패치 준비 완료"
	case "patch_apply_requested":
		return "패치 적용 요청"
	case "patch_applied":
		return "패치 적용 결과"
	case "run_requested":
		return "실행 요청"
	case "run_finished":
		return "실행 결과"
	case "provider_message":
		return "Cursor 메시지"
	case "tool_activity":
		return "Cursor 요청 맥락"
	default:
		return "세션 이벤트"
	}
}

func sessionPlanDetail(stepID string, phase string) string {
	switch stepID {
	case "draft_patch":
		if phase == "prompting" {
			return "에이전트가 패치 초안을 준비하고 있습니다."
		}
		return "패치 초안이 준비되면 여기에서 검토할 수 있습니다."
	case "apply_patch":
		if phase == "reviewing" {
			return "검토 후 패치 적용 여부를 결정할 수 있습니다."
		}
		if phase == "applying" {
			return "패치를 워크스페이스에 반영하고 있습니다."
		}
		return "필요하면 패치를 워크스페이스에 적용합니다."
	case "verify_run":
		if phase == "running" {
			return "실행 결과와 터미널 출력이 곧 반영됩니다."
		}
		return "실행 검증 결과가 세션에 누적됩니다."
	default:
		return ""
	}
}

func sessionPlanSummary(items []SessionPlanItem, phase string) string {
	for _, item := range items {
		if item.Status == "failed" {
			return item.Label + " 단계에서 확인이 필요합니다."
		}
	}
	for _, item := range items {
		if item.Status == "in_progress" {
			return item.Label + " 진행 중입니다."
		}
	}
	switch strings.TrimSpace(phase) {
	case "reviewing":
		return "패치와 작업 로그를 검토할 수 있습니다."
	case "applied":
		return "패치가 적용되었고 다음 검증을 진행할 수 있습니다."
	case "waiting_input":
		return "다음 입력이나 승인을 기다리는 상태입니다."
	case "running":
		return "실행 검증 결과를 수집하고 있습니다."
	case "prompting":
		return "에이전트가 요청을 분석하고 있습니다."
	default:
		return "세션 흐름이 여기에 정리됩니다."
	}
}

func planStatus(completed bool, inProgress bool, failed bool) string {
	if failed {
		return "failed"
	}
	if completed {
		return "completed"
	}
	if inProgress {
		return "in_progress"
	}
	return "pending"
}

func statusFromPresence(completed bool, failed bool) string {
	if failed {
		return "failed"
	}
	if completed {
		return "completed"
	}
	return "pending"
}
func phaseFromThreadSummary(thread ThreadSummary) string {
	if thread.LastEventKind == "patch_apply_requested" {
		return "applying"
	}
	if thread.LastEventKind == "run_requested" {
		return "running"
	}

	switch strings.ToLower(strings.TrimSpace(thread.State)) {
	case "", "draft":
		return "idle"
	case "prompt_submitted":
		return "prompting"
	case "patch_ready":
		return "reviewing"
	case "applied", "success", "partial", "conflict":
		return "applied"
	case "completed", "failed":
		return "waiting_input"
	default:
		switch thread.LastEventKind {
		case "prompt_submitted", "prompt_accepted":
			return "prompting"
		case "patch_ready":
			return "reviewing"
		case "patch_applied":
			return "applied"
		case "run_finished":
			return "waiting_input"
		default:
			return "idle"
		}
	}
}

func patchPathsFromAny(value any) []string {
	switch typed := value.(type) {
	case []protocol.FilePatch:
		return patchFilePaths(typed)
	case []any:
		paths := make([]string, 0, len(typed))
		seen := make(map[string]struct{}, len(typed))
		for _, item := range typed {
			path := ""
			switch file := item.(type) {
			case map[string]any:
				path = stringValue(file["path"])
			case protocol.FilePatch:
				path = strings.TrimSpace(file.Path)
			}
			if path == "" {
				continue
			}
			if _, ok := seen[path]; ok {
				continue
			}
			seen[path] = struct{}{}
			paths = append(paths, path)
		}
		return paths
	default:
		return nil
	}
}

func stringSliceFromAny(value any) []string {
	switch typed := value.(type) {
	case []string:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			item = strings.TrimSpace(item)
			if item != "" {
				out = append(out, item)
			}
		}
		return dedupeStrings(out)
	case []any:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			text := stringValue(item)
			if text != "" {
				out = append(out, text)
			}
		}
		return dedupeStrings(out)
	default:
		return nil
	}
}

func sessionRunErrorsFromAny(value any) []SessionRunError {
	switch typed := value.(type) {
	case []protocol.ParsedError:
		out := make([]SessionRunError, 0, len(typed))
		for _, item := range typed {
			path := strings.TrimSpace(item.Path)
			message := strings.TrimSpace(item.Message)
			if path == "" && message == "" && item.Line == 0 {
				continue
			}
			out = append(out, SessionRunError{Path: path, Line: item.Line, Message: message})
		}
		return out
	case []any:
		out := make([]SessionRunError, 0, len(typed))
		for _, raw := range typed {
			item, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			path := stringValue(item["path"])
			message := stringValue(item["message"])
			line := intValue(item["line"])
			if path == "" && message == "" && line == 0 {
				continue
			}
			out = append(out, SessionRunError{Path: path, Line: line, Message: message})
		}
		return out
	default:
		return nil
	}
}

func firstParsedErrorMessage(value any) string {
	_, _, message := firstParsedError(value)
	return message
}

func firstParsedError(value any) (string, int, string) {
	switch typed := value.(type) {
	case []protocol.ParsedError:
		for _, item := range typed {
			message := strings.TrimSpace(item.Message)
			path := strings.TrimSpace(item.Path)
			if message == "" && path == "" && item.Line == 0 {
				continue
			}
			return path, item.Line, message
		}
	case []any:
		for _, raw := range typed {
			item, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			message := stringValue(item["message"])
			path := stringValue(item["path"])
			line := intValue(item["line"])
			if message == "" && path == "" && line == 0 {
				continue
			}
			return path, line, message
		}
	}
	return "", 0, ""
}

func cloneStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	out := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			out = append(out, value)
		}
	}
	return dedupeStrings(out)
}

func dedupeStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	out := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
}

func firstNonEmptyStrings(groups ...[]string) []string {
	for _, group := range groups {
		if len(group) == 0 {
			continue
		}
		return cloneStrings(group)
	}
	return nil
}

func firstString(values []string) string {
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			return value
		}
	}
	return ""
}

func firstNonZero(values ...int64) int64 {
	for _, value := range values {
		if value != 0 {
			return value
		}
	}
	return 0
}
func stringValue(value any) string {
	text, ok := value.(string)
	if !ok {
		return ""
	}
	return strings.TrimSpace(text)
}

func intValue(value any) int {
	switch typed := value.(type) {
	case int:
		return typed
	case int32:
		return int(typed)
	case int64:
		return int(typed)
	case float64:
		return int(typed)
	default:
		return 0
	}
}
