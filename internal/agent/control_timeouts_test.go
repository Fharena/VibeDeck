package agent

import (
	"testing"
	"time"

	"github.com/Fharena/VibeDeck/internal/protocol"
)

func TestControlEnvelopeTimeout(t *testing.T) {
	cfg := DefaultControlTimeoutConfig()
	cases := []struct {
		name string
		typ  protocol.MessageType
		want time.Duration
	}{
		{name: "prompt", typ: protocol.TypePromptSubmit, want: 5 * time.Minute},
		{name: "run", typ: protocol.TypeRunProfile, want: 5 * time.Minute},
		{name: "patch", typ: protocol.TypePatchApply, want: 30 * time.Second},
		{name: "ack", typ: protocol.TypeCmdAck, want: 5 * time.Second},
	}

	for _, tc := range cases {
		if got := cfg.TimeoutFor(tc.typ); got != tc.want {
			t.Fatalf("%s: want %s, got %s", tc.name, tc.want, got)
		}
	}
}

func TestLoadControlTimeoutConfigFromEnv(t *testing.T) {
	t.Setenv("CONTROL_TIMEOUT_DEFAULT", "9s")
	t.Setenv("CONTROL_TIMEOUT_PROMPT_SUBMIT", "7m")
	t.Setenv("CONTROL_TIMEOUT_PATCH_APPLY", "45s")
	t.Setenv("CONTROL_TIMEOUT_RUN_PROFILE", "8m")

	cfg := LoadControlTimeoutConfigFromEnv()

	if cfg.Default != 9*time.Second {
		t.Fatalf("expected default timeout 9s, got %s", cfg.Default)
	}
	if cfg.PromptSubmit != 7*time.Minute {
		t.Fatalf("expected prompt timeout 7m, got %s", cfg.PromptSubmit)
	}
	if cfg.PatchApply != 45*time.Second {
		t.Fatalf("expected patch timeout 45s, got %s", cfg.PatchApply)
	}
	if cfg.RunProfile != 8*time.Minute {
		t.Fatalf("expected run timeout 8m, got %s", cfg.RunProfile)
	}

	view := cfg.View()
	if view.Default != "9s" || view.PromptSubmit != "7m" || view.PatchApply != "45s" || view.RunProfile != "8m" {
		t.Fatalf("unexpected control timeout view: %+v", view)
	}
}
