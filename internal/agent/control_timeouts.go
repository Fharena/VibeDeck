package agent

import (
	"fmt"
	"time"

	"github.com/Fharena/VibeDeck/internal/protocol"
)

type ControlTimeoutConfig struct {
	Default      time.Duration
	PromptSubmit time.Duration
	PatchApply   time.Duration
	RunProfile   time.Duration
}

type ControlTimeoutView struct {
	Default      string `json:"default"`
	PromptSubmit string `json:"promptSubmit"`
	PatchApply   string `json:"patchApply"`
	RunProfile   string `json:"runProfile"`
}

func DefaultControlTimeoutConfig() ControlTimeoutConfig {
	return ControlTimeoutConfig{
		Default:      5 * time.Second,
		PromptSubmit: 5 * time.Minute,
		PatchApply:   30 * time.Second,
		RunProfile:   5 * time.Minute,
	}
}

func LoadControlTimeoutConfigFromEnv() ControlTimeoutConfig {
	defaults := DefaultControlTimeoutConfig()
	return normalizeControlTimeoutConfig(ControlTimeoutConfig{
		Default:      durationEnv("CONTROL_TIMEOUT_DEFAULT", defaults.Default),
		PromptSubmit: durationEnv("CONTROL_TIMEOUT_PROMPT_SUBMIT", defaults.PromptSubmit),
		PatchApply:   durationEnv("CONTROL_TIMEOUT_PATCH_APPLY", defaults.PatchApply),
		RunProfile:   durationEnv("CONTROL_TIMEOUT_RUN_PROFILE", defaults.RunProfile),
	})
}

func normalizeControlTimeoutConfig(cfg ControlTimeoutConfig) ControlTimeoutConfig {
	defaults := DefaultControlTimeoutConfig()
	if cfg.Default <= 0 {
		cfg.Default = defaults.Default
	}
	if cfg.PromptSubmit <= 0 {
		cfg.PromptSubmit = defaults.PromptSubmit
	}
	if cfg.PatchApply <= 0 {
		cfg.PatchApply = defaults.PatchApply
	}
	if cfg.RunProfile <= 0 {
		cfg.RunProfile = defaults.RunProfile
	}
	return cfg
}

func (cfg ControlTimeoutConfig) TimeoutFor(messageType protocol.MessageType) time.Duration {
	cfg = normalizeControlTimeoutConfig(cfg)
	switch messageType {
	case protocol.TypePromptSubmit:
		return cfg.PromptSubmit
	case protocol.TypeRunProfile:
		return cfg.RunProfile
	case protocol.TypePatchApply:
		return cfg.PatchApply
	default:
		return cfg.Default
	}
}

func (cfg ControlTimeoutConfig) View() ControlTimeoutView {
	cfg = normalizeControlTimeoutConfig(cfg)
	return ControlTimeoutView{
		Default:      formatControlTimeoutLabel(cfg.Default),
		PromptSubmit: formatControlTimeoutLabel(cfg.PromptSubmit),
		PatchApply:   formatControlTimeoutLabel(cfg.PatchApply),
		RunProfile:   formatControlTimeoutLabel(cfg.RunProfile),
	}
}

func controlEnvelopeTimeout(messageType protocol.MessageType) time.Duration {
	return DefaultControlTimeoutConfig().TimeoutFor(messageType)
}

func formatControlTimeoutLabel(value time.Duration) string {
	if value <= 0 {
		return "0s"
	}
	if value%time.Minute == 0 {
		return fmt.Sprintf("%dm", value/time.Minute)
	}
	if value%time.Second == 0 {
		return fmt.Sprintf("%ds", value/time.Second)
	}
	return value.String()
}
