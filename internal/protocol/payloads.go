package protocol

type ContextOptions struct {
	IncludeActiveFile       bool `json:"includeActiveFile"`
	IncludeSelection        bool `json:"includeSelection"`
	IncludeLatestError      bool `json:"includeLatestError"`
	IncludeWorkspaceSummary bool `json:"includeWorkspaceSummary"`
}

type PromptSubmitPayload struct {
	ThreadID       string         `json:"threadId,omitempty"`
	Prompt         string         `json:"prompt"`
	Template       string         `json:"template,omitempty"`
	Model          string         `json:"model,omitempty"`
	ReasoningLevel string         `json:"reasoningLevel,omitempty"`
	ContextOptions ContextOptions `json:"contextOptions"`
}

type PromptAckPayload struct {
	ThreadID string `json:"threadId,omitempty"`
	JobID    string `json:"jobId"`
	Accepted bool   `json:"accepted"`
	Message  string `json:"message"`
}

type SelectedHunk struct {
	Path    string   `json:"path"`
	HunkIDs []string `json:"hunkIds"`
}

type PatchApplyPayload struct {
	JobID    string         `json:"jobId"`
	Mode     string         `json:"mode"`
	Selected []SelectedHunk `json:"selected,omitempty"`
}

type PatchResultPayload struct {
	JobID   string `json:"jobId"`
	Status  string `json:"status"`
	Message string `json:"message"`
}

type RunProfilePayload struct {
	JobID     string `json:"jobId"`
	ProfileID string `json:"profileId"`
}

type ParsedError struct {
	Message string `json:"message"`
	Path    string `json:"path,omitempty"`
	Line    int    `json:"line,omitempty"`
	Column  int    `json:"column,omitempty"`
}

type RunResultPayload struct {
	JobID        string        `json:"jobId"`
	ProfileID    string        `json:"profileId"`
	Status       string        `json:"status"`
	Summary      string        `json:"summary"`
	TopErrors    []ParsedError `json:"topErrors,omitempty"`
	Excerpt      string        `json:"excerpt,omitempty"`
	Output       string        `json:"output,omitempty"`
	ChangedFiles []string      `json:"changedFiles,omitempty"`
}

type OpenLocationPayload struct {
	Path   string `json:"path"`
	Line   int    `json:"line"`
	Column int    `json:"column,omitempty"`
}

type SignalOfferPayload struct {
	SDP string `json:"sdp"`
}

type SignalAnswerPayload struct {
	SDP string `json:"sdp"`
}

type SignalICEPayload struct {
	Candidate     string `json:"candidate"`
	SDPMid        string `json:"sdpMid,omitempty"`
	SDPMLineIndex int    `json:"sdpMLineIndex,omitempty"`
}

type SignalReadyPayload struct {
	Role          string `json:"role"`
	PeerConnected bool   `json:"peerConnected"`
	Timestamp     int64  `json:"timestamp"`
}

type TermSummaryPayload struct {
	SkippedLines int `json:"skippedLines"`
}

type CmdAckPayload struct {
	RequestRID string `json:"requestRid"`
	Accepted   bool   `json:"accepted"`
	Message    string `json:"message,omitempty"`
}

func NewCmdAck(sid string, seq int64, requestRID string, accepted bool, message string) (Envelope, error) {
	return NewEnvelope(
		sid,
		requestRID+"_ack",
		seq,
		TypeCmdAck,
		CmdAckPayload{
			RequestRID: requestRID,
			Accepted:   accepted,
			Message:    message,
		},
	)
}
