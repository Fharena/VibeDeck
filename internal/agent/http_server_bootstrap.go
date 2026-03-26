package agent

import (
	"net/http"
)

func (s *HTTPServer) handleBootstrap(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	adapterInfo := BasicAdapterRuntimeInfo(s.adapter)
	if provider, ok := s.adapter.(AdapterRuntimeInfoProvider); ok {
		adapterInfo = provider.RuntimeInfo()
	}

	configuredSignalingBaseURL := ""
	if s.p2pManager != nil {
		status := s.p2pManager.Status()
		configuredSignalingBaseURL = status.SignalingBaseURL
		if configuredSignalingBaseURL == "" {
			configuredSignalingBaseURL = s.p2pManager.DefaultSignalingBaseURL()
		}
	}

	threads := []ThreadSummary{}
	if s.orchestrator != nil && s.orchestrator.ThreadStore() != nil {
		threads = s.orchestrator.ThreadStore().List()
	}
	if len(threads) > s.config.BootstrapRecentThreadLimit {
		threads = threads[:s.config.BootstrapRecentThreadLimit]
	}

	recentThreads := make([]BootstrapThreadView, 0, len(threads))
	currentThreadID := ""
	currentSessionID := ""
	if s.orchestrator != nil && s.orchestrator.SessionStore() != nil {
		currentSessionID = s.orchestrator.SessionStore().CurrentSessionID()
	}
	for i, thread := range threads {
		current := i == 0
		if current {
			currentThreadID = thread.ID
		}
		recentThreads = append(recentThreads, BootstrapThreadView{
			ID:        thread.ID,
			Title:     thread.Title,
			UpdatedAt: thread.UpdatedAt,
			Current:   current,
		})
	}

	response := BootstrapResponse{
		AgentBaseURL:     inferAgentBaseURL(r, s.config.PublicAgentBaseURL),
		SignalingBaseURL: resolveBootstrapSignalingBaseURL(r, configuredSignalingBaseURL, s.config.PublicSignalingBaseURL),
		WorkspaceRoot:    adapterInfo.WorkspaceRoot,
		Adapter: BootstrapAdapterView{
			Name:     adapterInfo.Name,
			Mode:     adapterInfo.Mode,
			Provider: inferProviderName(adapterInfo),
			Ready:    adapterInfo.Ready,
		},
		ControlTimeouts:  s.config.ControlTimeouts.View(),
		CurrentThreadID:  currentThreadID,
		CurrentSessionID: currentSessionID,
		RecentThreads:    recentThreads,
	}
	writeJSON(w, http.StatusOK, response)
}
