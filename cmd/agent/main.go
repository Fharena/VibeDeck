package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/Fharena/VibeDeck/internal/agent"
	"github.com/Fharena/VibeDeck/internal/runtime"
)

func main() {
	addr := envOr("AGENT_ADDR", ":8080")
	profilePath := envOr("RUN_PROFILE_FILE", "configs/run-profiles.json")
	signalingBaseURL := envOr("SIGNALING_BASE_URL", "http://127.0.0.1:8081")
	agentPublicBaseURL := envOr("AGENT_PUBLIC_BASE_URL", "")
	signalingPublicBaseURL := envOr("SIGNALING_PUBLIC_BASE_URL", "")
	threadStorePath := envOr("THREAD_STORE_FILE", defaultThreadStorePath())
	controlTimeouts := agent.LoadControlTimeoutConfigFromEnv()

	profiles, err := agent.LoadRunProfiles(profilePath)
	if err != nil {
		log.Fatalf("load run profiles: %v", err)
	}

	adapter, adapterCloser, err := agent.NewWorkspaceAdapterFromEnv(context.Background())
	if err != nil {
		log.Fatalf("create workspace adapter: %v", err)
	}
	if adapterCloser != nil {
		defer func() {
			if closeErr := adapterCloser.Close(); closeErr != nil {
				log.Printf("close workspace adapter: %v", closeErr)
			}
		}()
	}

	threadStore, err := agent.NewPersistentThreadStore(threadStorePath)
	if err != nil {
		log.Fatalf("create thread store: %v", err)
	}
	orchestrator := agent.NewOrchestrator(adapter, profiles, threadStore)

	stateManager := runtime.NewStateManager(runtime.DefaultManagerConfig())
	ackTracker := runtime.NewAckTracker(2 * time.Second)
	controlMetrics := agent.NewControlMetrics()
	p2pManager := agent.NewP2PSessionManager(stateManager, ackTracker, orchestrator, signalingBaseURL)
	p2pManager.SetControlMetrics(controlMetrics)
	p2pManager.SetControlTimeouts(controlTimeouts)

	server := agent.NewHTTPServer(adapter, orchestrator, stateManager, ackTracker, controlMetrics, p2pManager, agent.HTTPServerConfig{
		PublicAgentBaseURL:     agentPublicBaseURL,
		PublicSignalingBaseURL: signalingPublicBaseURL,
		ControlTimeouts:        controlTimeouts,
	})

	log.Printf("agent server listening on %s (adapter=%s, threadStore=%s)", addr, adapter.Name(), threadStorePath)
	if err := http.ListenAndServe(addr, server.Handler()); err != nil {
		log.Fatal(err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func defaultThreadStorePath() string {
	configDir, err := os.UserConfigDir()
	if err == nil && strings.TrimSpace(configDir) != "" {
		return filepath.Join(configDir, "VibeDeck", "thread-store.json")
	}
	return filepath.Join("data", "thread-store.json")
}
