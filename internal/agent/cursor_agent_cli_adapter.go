package agent

import (
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"

	"github.com/Fharena/VibeDeck/internal/protocol"
)

type CursorAgentCLIConfig struct {
	WorkspaceRoot        string
	TempRoot             string
	GitBin               string
	CursorAgentBin       string
	CursorAgentArgs      []string
	CursorAgentEnv       []string
	SyncIgnoredPaths     []string
	CursorAgentUseWSL    bool
	CursorAgentWSLDistro string
	CursorAgentWSLBinary string
	PromptTimeout        time.Duration
	RunTimeout           time.Duration
}

type CursorAgentCLIAdapter struct {
	cfg CursorAgentCLIConfig

	taskSeq atomic.Int64
	runSeq  atomic.Int64

	mu                  sync.RWMutex
	tasks               map[string]*cursorAgentTask
	runs                map[string]*RunResult
	lastRunProfile      string
	lastRunStatus       string
	latestTerminalError string
	resolvedGitBin      string
	resolvedCursorAgent string
}

type cursorAgentTask struct {
	TaskID         string
	Prompt         string
	Summary        string
	RawDiff        string
	Parsed         unifiedPatch
	Patch          *protocol.PatchReadyPayload
	ProviderEvents []ProviderVisibleEvent
	CreatedAt      time.Time
}

type unifiedPatch struct {
	Files []unifiedPatchFile
}

type unifiedPatchFile struct {
	Path        string
	Status      string
	HeaderLines []string
	Hunks       []unifiedPatchHunk
}

type unifiedPatchHunk struct {
	HunkID string
	Header string
	Lines  []string
}

type cursorAgentJSONOutput struct {
	Type    string `json:"type"`
	Result  string `json:"result"`
	Text    string `json:"text"`
	Output  string `json:"output"`
	Summary string `json:"summary"`
	Message string `json:"message"`
}

func DefaultCursorAgentCLIConfig() (CursorAgentCLIConfig, error) {
	workspaceRoot := strings.TrimSpace(os.Getenv("CURSOR_AGENT_WORKSPACE_ROOT"))
	if workspaceRoot == "" {
		cwd, err := os.Getwd()
		if err != nil {
			return CursorAgentCLIConfig{}, fmt.Errorf("get working directory: %w", err)
		}
		workspaceRoot = cwd
	}

	cursorAgentArgs, err := jsonStringArrayEnv("CURSOR_AGENT_ARGS_JSON")
	if err != nil {
		return CursorAgentCLIConfig{}, err
	}
	if len(cursorAgentArgs) == 0 {
		cursorAgentArgs = []string{"--print", "--output-format", "json"}
	}
	cursorAgentArgs = ensureCursorAgentTrustFlag(cursorAgentArgs, trustWorkspaceEnv("CURSOR_AGENT_TRUST_WORKSPACE", true))
	cursorAgentArgs = ensureCursorAgentModelArg(cursorAgentArgs, defaultCursorAgentModel())

	cursorAgentEnv, err := jsonStringArrayEnv("CURSOR_AGENT_ENV_JSON")
	if err != nil {
		return CursorAgentCLIConfig{}, err
	}

	syncIgnoredPaths, err := jsonStringArrayEnv("CURSOR_AGENT_SYNC_IGNORED_JSON")
	if err != nil {
		return CursorAgentCLIConfig{}, err
	}

	gitBin := strings.TrimSpace(os.Getenv("CURSOR_AGENT_GIT_BIN"))
	if gitBin == "" {
		gitBin = "git"
	}

	cursorAgentBin := strings.TrimSpace(os.Getenv("CURSOR_AGENT_BIN"))
	if cursorAgentBin == "" {
		cursorAgentBin = "cursor-agent"
	}
	useWSL := boolEnv("CURSOR_AGENT_USE_WSL")
	wslDistro := strings.TrimSpace(os.Getenv("CURSOR_AGENT_WSL_DISTRO"))
	wslBinary := ""
	if useWSL {
		cursorAgentBin = defaultWSLExecutable(cursorAgentBin)
		resolvedWSL, err := resolveWSLCursorAgent(cursorAgentBin, wslDistro)
		if err != nil {
			return CursorAgentCLIConfig{}, err
		}
		wslDistro = resolvedWSL.Distro
		wslBinary = resolvedWSL.Binary
		cursorAgentArgs = buildWSLCursorAgentArgs(wslDistro, wslBinary, cursorAgentArgs)
	}

	return CursorAgentCLIConfig{
		WorkspaceRoot:        workspaceRoot,
		TempRoot:             strings.TrimSpace(os.Getenv("CURSOR_AGENT_TEMP_ROOT")),
		GitBin:               gitBin,
		CursorAgentBin:       cursorAgentBin,
		CursorAgentArgs:      cursorAgentArgs,
		CursorAgentEnv:       cursorAgentEnv,
		SyncIgnoredPaths:     sanitizeSyncPathspecs(syncIgnoredPaths),
		CursorAgentUseWSL:    useWSL,
		CursorAgentWSLDistro: wslDistro,
		CursorAgentWSLBinary: wslBinary,
		PromptTimeout:        durationEnv("CURSOR_AGENT_PROMPT_TIMEOUT", 2*time.Minute),
		RunTimeout:           durationEnv("CURSOR_AGENT_RUN_TIMEOUT", 2*time.Minute),
	}, nil
}

func NewCursorAgentCLIAdapter(ctx context.Context, cfg CursorAgentCLIConfig) (*CursorAgentCLIAdapter, error) {
	if strings.TrimSpace(cfg.GitBin) == "" {
		return nil, errors.New("cursor agent git binary is required")
	}
	if strings.TrimSpace(cfg.CursorAgentBin) == "" {
		return nil, errors.New("cursor agent binary is required")
	}
	if strings.TrimSpace(cfg.WorkspaceRoot) == "" {
		cwd, err := os.Getwd()
		if err != nil {
			return nil, fmt.Errorf("get working directory: %w", err)
		}
		cfg.WorkspaceRoot = cwd
	}
	gitPath, err := exec.LookPath(cfg.GitBin)
	if err != nil {
		return nil, fmt.Errorf("find git binary %q: %w", cfg.GitBin, err)
	}
	cursorAgentPath, err := exec.LookPath(cfg.CursorAgentBin)
	if err != nil {
		return nil, fmt.Errorf("find cursor-agent binary %q: %w", cfg.CursorAgentBin, err)
	}

	repoRoot, err := gitTopLevel(ctx, cfg.GitBin, cfg.WorkspaceRoot)
	if err != nil {
		return nil, err
	}
	cfg.WorkspaceRoot = repoRoot

	return &CursorAgentCLIAdapter{
		cfg:                 cfg,
		tasks:               make(map[string]*cursorAgentTask),
		runs:                make(map[string]*RunResult),
		resolvedGitBin:      gitPath,
		resolvedCursorAgent: cursorAgentPath,
	}, nil
}

func (a *CursorAgentCLIAdapter) Name() string {
	return "cursor-agent-cli"
}

func (a *CursorAgentCLIAdapter) RuntimeInfo() AdapterRuntimeInfo {
	info := AdapterRuntimeInfo{
		Name:          a.Name(),
		Mode:          "cursor_agent_cli",
		Ready:         true,
		Capabilities:  a.Capabilities(),
		WorkspaceRoot: a.cfg.WorkspaceRoot,
		Binary:        a.cfg.CursorAgentBin,
		BinaryPath:    a.resolvedCursorAgent,
		TempRoot:      a.cfg.TempRoot,
		PromptTimeout: a.cfg.PromptTimeout.String(),
		RunTimeout:    a.cfg.RunTimeout.String(),
	}
	info.Notes = []string{
		"cursor-agent runs inside a temporary git worktree snapshot",
		"review approval applies the resulting diff to the real workspace with git apply",
	}
	if a.resolvedGitBin != "" {
		info.Notes = append(info.Notes, "git binary: "+a.resolvedGitBin)
	}
	if a.cfg.CursorAgentUseWSL {
		info.Notes = append(info.Notes, wslCursorAgentNote(a.cfg.CursorAgentWSLDistro))
		if a.cfg.CursorAgentWSLBinary != "" {
			info.Notes = append(info.Notes, "wsl cursor-agent binary: "+a.cfg.CursorAgentWSLBinary)
		}
	}
	return info
}

func (a *CursorAgentCLIAdapter) Capabilities() AdapterCapabilities {
	return AdapterCapabilities{
		SupportsPartialApply:     true,
		SupportsStructuredPatch:  true,
		SupportsContextSelection: false,
		SupportsArtifacts:        false,
		SupportsOpenLocation:     false,
	}
}

func (a *CursorAgentCLIAdapter) GetContext(ctx context.Context, input ContextRequest) (WorkspaceContext, error) {
	changedFiles := []string{}
	if input.Options.IncludeWorkspaceSummary {
		files, err := a.listChangedFiles(ctx)
		if err != nil {
			return WorkspaceContext{}, err
		}
		changedFiles = files
	}

	a.mu.RLock()
	lastRunProfile := a.lastRunProfile
	lastRunStatus := a.lastRunStatus
	latestTerminalError := a.latestTerminalError
	a.mu.RUnlock()

	result := WorkspaceContext{}
	if input.Options.IncludeWorkspaceSummary {
		result.ChangedFiles = changedFiles
		result.LastRunProfile = lastRunProfile
		result.LastRunStatus = lastRunStatus
	}
	if input.Options.IncludeLatestError {
		result.LatestTerminalError = latestTerminalError
	}
	return result, nil
}

func (a *CursorAgentCLIAdapter) SubmitTask(ctx context.Context, input SubmitTaskInput) (TaskHandle, error) {
	taskID := fmt.Sprintf("task_%d", a.taskSeq.Add(1))
	task, err := a.generateTask(ctx, taskID, input)
	if err != nil {
		return TaskHandle{}, err
	}

	a.mu.Lock()
	a.tasks[taskID] = task
	a.mu.Unlock()

	return TaskHandle{
		TaskID:         taskID,
		ProviderEvents: cloneProviderVisibleEvents(task.ProviderEvents),
	}, nil
}

func (a *CursorAgentCLIAdapter) GetPatch(_ context.Context, taskID string) (*protocol.PatchReadyPayload, error) {
	a.mu.RLock()
	task, ok := a.tasks[taskID]
	a.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("task %s not found", taskID)
	}
	return clonePatchReadyPayload(task.Patch), nil
}

func (a *CursorAgentCLIAdapter) ApplyPatch(ctx context.Context, input ApplyPatchInput) (ApplyPatchResult, error) {
	a.mu.RLock()
	task, ok := a.tasks[input.TaskID]
	a.mu.RUnlock()
	if !ok {
		return ApplyPatchResult{Status: "failed", Message: "task not found"}, nil
	}

	patchText, selectedCount, err := buildPatchForApply(task, input)
	if err != nil {
		return ApplyPatchResult{Status: "failed", Message: err.Error()}, nil
	}
	if strings.TrimSpace(patchText) == "" {
		return ApplyPatchResult{Status: "success", Message: "no patch changes to apply"}, nil
	}

	if _, err := a.runGitWithInput(ctx, a.cfg.WorkspaceRoot, patchText, "apply", "--check", "--binary", "--whitespace=nowarn"); err != nil {
		return ApplyPatchResult{Status: "conflict", Message: err.Error()}, nil
	}
	if _, err := a.runGitWithInput(ctx, a.cfg.WorkspaceRoot, patchText, "apply", "--binary", "--whitespace=nowarn"); err != nil {
		return ApplyPatchResult{Status: "failed", Message: err.Error()}, nil
	}

	message := "patch applied"
	if input.Mode == "selected" {
		message = fmt.Sprintf("selected hunks applied (%d)", selectedCount)
	}
	return ApplyPatchResult{Status: "success", Message: message}, nil
}

func (a *CursorAgentCLIAdapter) RunProfile(ctx context.Context, input RunProfileInput) (RunHandle, error) {
	runID := fmt.Sprintf("run_%s_%d", input.ProfileID, a.runSeq.Add(1))
	result := a.executeRunProfile(ctx, runID, input)

	a.mu.Lock()
	a.runs[runID] = result
	a.lastRunProfile = input.ProfileID
	a.lastRunStatus = result.Status
	a.latestTerminalError = ""
	if result.Status != "passed" {
		a.latestTerminalError = firstNonEmptyLine(result.Excerpt)
	}
	a.mu.Unlock()

	return RunHandle{RunID: runID}, nil
}

func (a *CursorAgentCLIAdapter) GetRunResult(_ context.Context, runID string) (*RunResult, error) {
	a.mu.RLock()
	result, ok := a.runs[runID]
	a.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("run %s not found", runID)
	}
	copied := *result
	if len(result.TopErrors) > 0 {
		copied.TopErrors = append([]protocol.ParsedError(nil), result.TopErrors...)
	}
	return &copied, nil
}

func (a *CursorAgentCLIAdapter) OpenLocation(_ context.Context, _ OpenLocationInput) error {
	return nil
}

func (a *CursorAgentCLIAdapter) generateTask(ctx context.Context, taskID string, input SubmitTaskInput) (*cursorAgentTask, error) {
	worktreeParent, err := os.MkdirTemp(a.cfg.TempRoot, "vibedeck-cursor-agent-*")
	if err != nil {
		return nil, fmt.Errorf("create cursor-agent temp dir: %w", err)
	}
	worktreeDir := filepath.Join(worktreeParent, "worktree")

	cleanup := func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_, _ = a.runGit(cleanupCtx, a.cfg.WorkspaceRoot, "worktree", "remove", "--force", worktreeDir)
		_ = os.RemoveAll(worktreeParent)
	}
	defer cleanup()

	if _, err := a.runGit(ctx, a.cfg.WorkspaceRoot, "worktree", "add", "--detach", worktreeDir); err != nil {
		return nil, err
	}
	if err := a.syncWorkspaceIntoWorktree(ctx, worktreeDir); err != nil {
		return nil, err
	}
	if err := a.commitWorktreeBaseline(ctx, worktreeDir); err != nil {
		return nil, err
	}

	prompt := buildCursorAgentPrompt(input)
	cursorOutput, err := a.runCursorAgent(ctx, worktreeDir, prompt, input.Model)
	if err != nil {
		return nil, err
	}
	if err := a.stageUntrackedFilesForDiff(ctx, worktreeDir); err != nil {
		return nil, err
	}

	rawDiff, err := a.runGit(ctx, worktreeDir, "diff", "--binary", "HEAD", "--", ".")
	if err != nil {
		return nil, err
	}
	parsed, err := parseUnifiedPatch(rawDiff)
	if err != nil {
		return nil, err
	}
	patchPayload := parsed.toPatchReadyPayload(taskSummary(cursorOutput, parsed))
	providerEvents := buildProviderVisibleEvents(cursorOutput, patchPayload)

	return &cursorAgentTask{
		TaskID:         taskID,
		Prompt:         input.Prompt,
		Summary:        patchPayload.Summary,
		RawDiff:        rawDiff,
		Parsed:         parsed,
		Patch:          patchPayload,
		ProviderEvents: providerEvents,
		CreatedAt:      time.Now().UTC(),
	}, nil
}

func (a *CursorAgentCLIAdapter) listChangedFiles(ctx context.Context) ([]string, error) {
	output, err := a.runGit(ctx, a.cfg.WorkspaceRoot, "status", "--short", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(output) == "" {
		return []string{}, nil
	}

	seen := make(map[string]struct{})
	for _, line := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || len(line) < 3 {
			continue
		}
		path := strings.TrimSpace(line[3:])
		if arrow := strings.LastIndex(path, " -> "); arrow >= 0 {
			path = strings.TrimSpace(path[arrow+4:])
		}
		if path == "" {
			continue
		}
		seen[filepath.ToSlash(path)] = struct{}{}
	}

	files := make([]string, 0, len(seen))
	for path := range seen {
		files = append(files, path)
	}
	sort.Strings(files)
	return files, nil
}

func (a *CursorAgentCLIAdapter) syncWorkspaceIntoWorktree(ctx context.Context, worktreeDir string) error {
	trackedDiff, err := a.runGit(ctx, a.cfg.WorkspaceRoot, "diff", "--binary", "HEAD", "--", ".")
	if err != nil {
		return err
	}
	if strings.TrimSpace(trackedDiff) != "" {
		if _, err := a.runGitWithInput(ctx, worktreeDir, trackedDiff, "apply", "--binary", "--whitespace=nowarn"); err != nil {
			return fmt.Errorf("apply workspace tracked changes to temp worktree: %w", err)
		}
	}

	snapshotFiles, err := a.listSnapshotFiles(ctx)
	if err != nil {
		return err
	}
	for _, path := range snapshotFiles {
		sourcePath := filepath.Join(a.cfg.WorkspaceRoot, filepath.FromSlash(path))
		targetPath := filepath.Join(worktreeDir, filepath.FromSlash(path))
		if err := copyFile(sourcePath, targetPath); err != nil {
			return fmt.Errorf("copy workspace snapshot file %s: %w", path, err)
		}
	}
	return nil
}

func (a *CursorAgentCLIAdapter) stageUntrackedFilesForDiff(ctx context.Context, worktreeDir string) error {
	output, err := a.runGit(ctx, worktreeDir, "ls-files", "--others", "--exclude-standard")
	if err != nil {
		return err
	}

	paths := make([]string, 0)
	for _, line := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		path := strings.TrimSpace(line)
		if path == "" {
			continue
		}
		paths = append(paths, path)
	}
	if len(paths) == 0 {
		return nil
	}

	args := []string{"add", "-N", "--"}
	args = append(args, paths...)
	if _, err := a.runGit(ctx, worktreeDir, args...); err != nil {
		return fmt.Errorf("stage untracked files for diff: %w", err)
	}
	return nil
}

func (a *CursorAgentCLIAdapter) listSnapshotFiles(ctx context.Context) ([]string, error) {
	files := make([]string, 0)
	seen := make(map[string]struct{})

	appendGitOutput := func(output string) {
		for _, line := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
			path := strings.TrimSpace(line)
			if path == "" {
				continue
			}
			if _, ok := seen[path]; ok {
				continue
			}
			seen[path] = struct{}{}
			files = append(files, path)
		}
	}

	untrackedOutput, err := a.runGit(ctx, a.cfg.WorkspaceRoot, "ls-files", "--others", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	appendGitOutput(untrackedOutput)

	if len(a.cfg.SyncIgnoredPaths) > 0 {
		args := []string{"ls-files", "--others", "--ignored", "--exclude-standard", "--"}
		args = append(args, a.cfg.SyncIgnoredPaths...)
		ignoredOutput, err := a.runGit(ctx, a.cfg.WorkspaceRoot, args...)
		if err != nil {
			return nil, fmt.Errorf("list ignored snapshot files: %w", err)
		}
		appendGitOutput(ignoredOutput)
	}

	sort.Strings(files)
	return files, nil
}

func (a *CursorAgentCLIAdapter) commitWorktreeBaseline(ctx context.Context, worktreeDir string) error {
	status, err := a.runGit(ctx, worktreeDir, "status", "--short", "--untracked-files=all")
	if err != nil {
		return err
	}
	if strings.TrimSpace(status) == "" {
		return nil
	}
	if _, err := a.runGit(ctx, worktreeDir, "add", "-A"); err != nil {
		return err
	}
	_, err = a.runGit(
		ctx,
		worktreeDir,
		"-c", "user.name=VibeDeck",
		"-c", "user.email=vibedeck@example.local",
		"commit", "--quiet", "-m", "vibedeck baseline",
	)
	if err != nil {
		return fmt.Errorf("commit temp worktree baseline: %w", err)
	}
	return nil
}

func (a *CursorAgentCLIAdapter) runCursorAgent(ctx context.Context, worktreeDir, prompt, modelOverride string) (string, error) {
	promptCtx, cancel := withOptionalTimeout(ctx, a.cfg.PromptTimeout)
	defer cancel()

	args := withCursorAgentModelArg(a.cfg.CursorAgentArgs, modelOverride)
	args = append(args, prompt)
	stdout, stderr, err := runCommand(promptCtx, worktreeDir, a.cfg.CursorAgentEnv, nil, a.cfg.CursorAgentBin, args...)
	if err != nil {
		message := strings.TrimSpace(stderr)
		if message == "" {
			message = strings.TrimSpace(stdout)
		}
		if message == "" {
			message = err.Error()
		}
		return "", fmt.Errorf("cursor-agent execution failed: %s", compactMessage(message))
	}
	if strings.TrimSpace(stdout) == "" {
		return strings.TrimSpace(stderr), nil
	}
	return stdout, nil
}

func (a *CursorAgentCLIAdapter) executeRunProfile(ctx context.Context, runID string, input RunProfileInput) *RunResult {
	if strings.TrimSpace(input.Command) == "" || input.Command == "dynamic" {
		return &RunResult{
			RunID:     runID,
			ProfileID: input.ProfileID,
			Status:    "failed",
			Summary:   "dynamic run profile is not configured for cursor_agent_cli",
			TopErrors: []protocol.ParsedError{{Message: "dynamic run profile is not configured"}},
			Excerpt:   "dynamic run profile is not configured",
			Output:    "dynamic run profile is not configured",
		}
	}

	runCtx, cancel := withOptionalTimeout(ctx, a.cfg.RunTimeout)
	defer cancel()

	name, args := platformShellCommand(input.Command)
	stdout, stderr, err := runCommand(runCtx, a.cfg.WorkspaceRoot, nil, nil, name, args...)
	combined := strings.TrimSpace(strings.Join(nonEmptyStrings(stdout, stderr), "\n"))
	status := "passed"
	summary := "command completed successfully"
	if err != nil {
		status = "failed"
		summary = fmt.Sprintf("command failed: %s", compactMessage(err.Error()))
	}
	if status == "passed" && combined != "" {
		summary = firstNonEmptyLine(combined)
	}

	result := &RunResult{
		RunID:     runID,
		ProfileID: input.ProfileID,
		Status:    status,
		Summary:   summary,
		Excerpt:   lastLines(combined, 20),
		Output:    combined,
	}
	if status != "passed" {
		message := firstNonEmptyLine(combined)
		if message == "" {
			message = compactMessage(err.Error())
		}
		result.TopErrors = []protocol.ParsedError{{Message: message}}
	}
	return result
}

func (a *CursorAgentCLIAdapter) runGit(ctx context.Context, dir string, args ...string) (string, error) {
	stdout, stderr, err := runCommand(ctx, dir, nil, nil, a.cfg.GitBin, args...)
	if err != nil {
		message := strings.TrimSpace(stderr)
		if message == "" {
			message = err.Error()
		}
		return "", fmt.Errorf("git %s failed: %s", strings.Join(args, " "), compactMessage(message))
	}
	return stdout, nil
}

func (a *CursorAgentCLIAdapter) runGitWithInput(ctx context.Context, dir, input string, args ...string) (string, error) {
	stdout, stderr, err := runCommand(ctx, dir, nil, strings.NewReader(input), a.cfg.GitBin, args...)
	if err != nil {
		message := strings.TrimSpace(stderr)
		if message == "" {
			message = err.Error()
		}
		return "", fmt.Errorf("git %s failed: %s", strings.Join(args, " "), compactMessage(message))
	}
	return stdout, nil
}

func gitTopLevel(ctx context.Context, gitBin, dir string) (string, error) {
	stdout, stderr, err := runCommand(ctx, dir, nil, nil, gitBin, "rev-parse", "--show-toplevel")
	if err != nil {
		message := strings.TrimSpace(stderr)
		if message == "" {
			message = err.Error()
		}
		return "", fmt.Errorf("detect git workspace root: %s", compactMessage(message))
	}
	root := strings.TrimSpace(stdout)
	if root == "" {
		return "", errors.New("git workspace root is empty")
	}
	return root, nil
}

func runCommand(ctx context.Context, dir string, env []string, stdin io.Reader, name string, args ...string) (string, string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	if len(env) > 0 {
		cmd.Env = append(os.Environ(), env...)
	}
	if stdin != nil {
		cmd.Stdin = stdin
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

func buildCursorAgentPrompt(input SubmitTaskInput) string {
	var builder strings.Builder
	builder.WriteString("You are running inside a disposable VibeDeck git worktree snapshot.\n")
	builder.WriteString("Apply the requested code changes directly to files in this workspace.\n")
	builder.WriteString("Do not create commits, do not rewrite unrelated files, and do not start long-running processes.\n")
	builder.WriteString("Keep the resulting diff as small and reviewable as possible.\n\n")
	if input.Template != "" {
		builder.WriteString("Template: ")
		builder.WriteString(input.Template)
		builder.WriteString("\n")
	}
	if input.Model != "" {
		builder.WriteString("Requested model: ")
		builder.WriteString(input.Model)
		builder.WriteString("\n")
	}
	if input.ReasoningLevel != "" {
		builder.WriteString("Reasoning level: ")
		builder.WriteString(input.ReasoningLevel)
		builder.WriteString("\n")
		builder.WriteString(reasoningInstruction(input.ReasoningLevel))
		builder.WriteString("\n")
	}
	builder.WriteString("User request:\n")
	builder.WriteString(strings.TrimSpace(input.Prompt))
	builder.WriteString("\n")

	if input.Context.ActiveFilePath != "" {
		builder.WriteString("\nActive file: ")
		builder.WriteString(filepath.ToSlash(input.Context.ActiveFilePath))
		builder.WriteString("\n")
	}
	if input.Context.Selection != "" {
		builder.WriteString("Selection:\n")
		builder.WriteString(input.Context.Selection)
		builder.WriteString("\n")
	}
	if input.Context.LatestTerminalError != "" {
		builder.WriteString("Latest terminal error:\n")
		builder.WriteString(input.Context.LatestTerminalError)
		builder.WriteString("\n")
	}
	if len(input.Context.ChangedFiles) > 0 {
		builder.WriteString("Changed files already in the workspace:\n")
		for _, path := range input.Context.ChangedFiles {
			builder.WriteString("- ")
			builder.WriteString(filepath.ToSlash(path))
			builder.WriteString("\n")
		}
	}
	return builder.String()
}

func reasoningInstruction(level string) string {
	switch strings.ToLower(strings.TrimSpace(level)) {
	case "low":
		return "Prefer a quick direct solution. Keep exploration and explanation short."
	case "high":
		return "Spend more time planning, verifying, and reviewing before editing files."
	default:
		return "Use a balanced amount of planning before editing files."
	}
}

func parseUnifiedPatch(raw string) (unifiedPatch, error) {
	raw = strings.ReplaceAll(raw, "\r\n", "\n")
	if strings.TrimSpace(raw) == "" {
		return unifiedPatch{}, nil
	}

	var patch unifiedPatch
	var current *unifiedPatchFile
	var currentHunk *unifiedPatchHunk
	hunkIndex := 0

	flushHunk := func() {
		if current == nil || currentHunk == nil {
			return
		}
		hunkIndex++
		currentHunk.HunkID = makeHunkID(current.Path, currentHunk.Header, currentHunk.Lines, hunkIndex)
		current.Hunks = append(current.Hunks, *currentHunk)
		currentHunk = nil
	}
	flushFile := func() {
		if current == nil {
			return
		}
		flushHunk()
		if current.Status == "" {
			current.Status = "modified"
		}
		patch.Files = append(patch.Files, *current)
		current = nil
		hunkIndex = 0
	}

	for _, line := range strings.Split(raw, "\n") {
		if strings.HasPrefix(line, "diff --git ") {
			flushFile()
			current = &unifiedPatchFile{
				Path:        parseDiffGitPath(line),
				Status:      "modified",
				HeaderLines: []string{line},
			}
			continue
		}
		if current == nil {
			continue
		}
		if strings.HasPrefix(line, "@@ ") {
			flushHunk()
			currentHunk = &unifiedPatchHunk{Header: line}
			continue
		}
		if currentHunk != nil {
			currentHunk.Lines = append(currentHunk.Lines, line)
			continue
		}

		current.HeaderLines = append(current.HeaderLines, line)
		switch {
		case strings.HasPrefix(line, "new file mode "):
			current.Status = "added"
		case strings.HasPrefix(line, "deleted file mode "):
			current.Status = "deleted"
		case strings.HasPrefix(line, "rename from ") || strings.HasPrefix(line, "rename to "):
			current.Status = "renamed"
		case strings.HasPrefix(line, "+++ "):
			path := parsePatchPath(strings.TrimSpace(strings.TrimPrefix(line, "+++ ")))
			if path != "" && path != "/dev/null" {
				current.Path = path
			}
		}
	}
	flushFile()
	return patch, nil
}

func (p unifiedPatch) toPatchReadyPayload(summary string) *protocol.PatchReadyPayload {
	files := make([]protocol.FilePatch, 0, len(p.Files))
	for _, file := range p.Files {
		hunks := make([]protocol.Hunk, 0, len(file.Hunks))
		for _, hunk := range file.Hunks {
			hunks = append(hunks, protocol.Hunk{
				HunkID: hunk.HunkID,
				Header: hunk.Header,
				Diff:   strings.Join(hunk.Lines, "\n"),
				Risk:   "medium",
			})
		}
		files = append(files, protocol.FilePatch{
			Path:   file.Path,
			Status: file.Status,
			Hunks:  hunks,
		})
	}
	if summary == "" {
		summary = fmt.Sprintf("Cursor Agent proposed changes in %d file(s)", len(files))
		if len(files) == 0 {
			summary = "Cursor Agent completed without code changes"
		}
	}
	return &protocol.PatchReadyPayload{Summary: summary, Files: files}
}

func buildPatchForApply(task *cursorAgentTask, input ApplyPatchInput) (string, int, error) {
	switch input.Mode {
	case "all", "":
		return task.RawDiff, countHunks(task.Parsed), nil
	case "selected":
		if len(input.Selected) == 0 {
			return "", 0, errors.New("selected mode requires hunk selection")
		}
		selected := make(map[string]map[string]struct{})
		for _, entry := range input.Selected {
			if _, ok := selected[entry.Path]; !ok {
				selected[entry.Path] = make(map[string]struct{})
			}
			for _, hunkID := range entry.HunkIDs {
				selected[entry.Path][hunkID] = struct{}{}
			}
		}

		filtered := unifiedPatch{}
		selectedCount := 0
		for _, file := range task.Parsed.Files {
			hunksByID, ok := selected[file.Path]
			if !ok {
				continue
			}
			filteredFile := unifiedPatchFile{
				Path:        file.Path,
				Status:      file.Status,
				HeaderLines: append([]string(nil), file.HeaderLines...),
			}
			for _, hunk := range file.Hunks {
				if _, ok := hunksByID[hunk.HunkID]; !ok {
					continue
				}
				filteredFile.Hunks = append(filteredFile.Hunks, hunk)
				selectedCount++
			}
			if len(filteredFile.Hunks) > 0 {
				filtered.Files = append(filtered.Files, filteredFile)
			}
		}
		if selectedCount == 0 {
			return "", 0, errors.New("selected hunks not found in patch")
		}
		return renderUnifiedPatch(filtered), selectedCount, nil
	default:
		return "", 0, fmt.Errorf("unsupported patch apply mode: %s", input.Mode)
	}
}

func renderUnifiedPatch(patch unifiedPatch) string {
	var builder strings.Builder
	for index, file := range patch.Files {
		if index > 0 {
			builder.WriteByte('\n')
		}
		for _, line := range file.HeaderLines {
			builder.WriteString(line)
			builder.WriteByte('\n')
		}
		for _, hunk := range file.Hunks {
			builder.WriteString(hunk.Header)
			builder.WriteByte('\n')
			for _, line := range hunk.Lines {
				builder.WriteString(line)
				builder.WriteByte('\n')
			}
		}
	}
	return builder.String()
}

func clonePatchReadyPayload(in *protocol.PatchReadyPayload) *protocol.PatchReadyPayload {
	if in == nil {
		return nil
	}
	out := &protocol.PatchReadyPayload{
		JobID:   in.JobID,
		Summary: in.Summary,
		Files:   make([]protocol.FilePatch, 0, len(in.Files)),
	}
	for _, file := range in.Files {
		copied := protocol.FilePatch{
			Path:   file.Path,
			Status: file.Status,
			Hunks:  make([]protocol.Hunk, len(file.Hunks)),
		}
		copy(copied.Hunks, file.Hunks)
		out.Files = append(out.Files, copied)
	}
	return out
}

func taskSummary(cursorOutput string, parsed unifiedPatch) string {
	summary := strings.TrimSpace(extractCursorAgentSummary(cursorOutput))
	if summary != "" {
		return summary
	}
	if len(parsed.Files) == 0 {
		return "Cursor Agent completed without code changes"
	}
	return fmt.Sprintf("Cursor Agent proposed changes in %d file(s)", len(parsed.Files))
}

func buildProviderVisibleEvents(cursorOutput string, patch *protocol.PatchReadyPayload) []ProviderVisibleEvent {
	body := truncateVisibleText(extractCursorAgentVisibleText(cursorOutput), 4000)
	if body == "" {
		return nil
	}

	fileCount := 0
	summary := ""
	if patch != nil {
		fileCount = len(patch.Files)
		summary = patch.Summary
	}

	return []ProviderVisibleEvent{{
		Kind:  "provider_message",
		Role:  "assistant",
		Title: "Cursor 응답",
		Body:  body,
		Data: map[string]any{
			"source":    "cursor_agent_cli",
			"summary":   summary,
			"fileCount": fileCount,
		},
	}}
}

func extractCursorAgentVisibleText(output string) string {
	trimmed := strings.TrimSpace(output)
	if trimmed == "" {
		return ""
	}

	var parsed cursorAgentJSONOutput
	if err := json.Unmarshal([]byte(trimmed), &parsed); err == nil {
		for _, candidate := range []string{parsed.Text, parsed.Output, parsed.Result, parsed.Summary, parsed.Message} {
			candidate = strings.TrimSpace(candidate)
			if candidate != "" {
				return candidate
			}
		}
	}

	return trimmed
}

func extractCursorAgentSummary(output string) string {
	trimmed := strings.TrimSpace(output)
	if trimmed == "" {
		return ""
	}
	var parsed cursorAgentJSONOutput
	if err := json.Unmarshal([]byte(trimmed), &parsed); err == nil {
		for _, candidate := range []string{parsed.Summary, parsed.Result, parsed.Text, parsed.Output, parsed.Message} {
			candidate = strings.TrimSpace(candidate)
			if candidate != "" {
				return firstNonEmptyLine(candidate)
			}
		}
	}
	return firstNonEmptyLine(trimmed)
}

func parseDiffGitPath(line string) string {
	parts := strings.Fields(line)
	if len(parts) >= 4 {
		candidate := parsePatchPath(parts[3])
		if candidate != "" && candidate != "/dev/null" {
			return candidate
		}
		candidate = parsePatchPath(parts[2])
		if candidate != "" && candidate != "/dev/null" {
			return candidate
		}
	}
	return ""
}

func parsePatchPath(value string) string {
	value = strings.TrimSpace(value)
	value = strings.Trim(value, "\"")
	if strings.HasPrefix(value, "a/") || strings.HasPrefix(value, "b/") {
		value = value[2:]
	}
	return filepath.ToSlash(value)
}

func makeHunkID(path, header string, lines []string, index int) string {
	hash := sha1.Sum([]byte(path + "\n" + header + "\n" + strings.Join(lines, "\n")))
	return fmt.Sprintf("h%d_%x", index, hash[:4])
}

func countHunks(patch unifiedPatch) int {
	count := 0
	for _, file := range patch.Files {
		count += len(file.Hunks)
	}
	return count
}

func copyFile(sourcePath, targetPath string) error {
	info, err := os.Stat(sourcePath)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		return err
	}
	source, err := os.Open(sourcePath)
	if err != nil {
		return err
	}
	defer source.Close()
	target, err := os.Create(targetPath)
	if err != nil {
		return err
	}
	defer target.Close()
	if _, err := io.Copy(target, source); err != nil {
		return err
	}
	return target.Chmod(info.Mode())
}

func truncateVisibleText(value string, maxLen int) string {
	trimmed := strings.TrimSpace(value)
	if len(trimmed) <= maxLen {
		return trimmed
	}
	if maxLen <= 3 {
		return trimmed[:maxLen]
	}
	return strings.TrimRightFunc(trimmed[:maxLen-3], unicode.IsSpace) + "..."
}

func cloneProviderVisibleEvents(events []ProviderVisibleEvent) []ProviderVisibleEvent {
	if len(events) == 0 {
		return nil
	}
	out := make([]ProviderVisibleEvent, 0, len(events))
	for _, event := range events {
		copied := ProviderVisibleEvent{
			Kind:  event.Kind,
			Role:  event.Role,
			Title: event.Title,
			Body:  event.Body,
		}
		if len(event.Data) > 0 {
			copied.Data = make(map[string]any, len(event.Data))
			for key, value := range event.Data {
				copied.Data[key] = value
			}
		}
		out = append(out, copied)
	}
	return out
}

func compactMessage(value string) string {
	value = strings.TrimSpace(strings.ReplaceAll(value, "\r\n", "\n"))
	if value == "" {
		return "unknown error"
	}
	return firstNonEmptyLine(value)
}

func firstNonEmptyLine(value string) string {
	for _, line := range strings.Split(strings.ReplaceAll(value, "\r\n", "\n"), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			return line
		}
	}
	return ""
}

func lastLines(value string, count int) string {
	if count <= 0 {
		return ""
	}
	lines := strings.Split(strings.ReplaceAll(strings.TrimSpace(value), "\r\n", "\n"), "\n")
	filtered := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		filtered = append(filtered, line)
	}
	if len(filtered) <= count {
		return strings.Join(filtered, "\n")
	}
	return strings.Join(filtered[len(filtered)-count:], "\n")
}

func nonEmptyStrings(values ...string) []string {
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			result = append(result, value)
		}
	}
	return result
}

func platformShellCommand(command string) (string, []string) {
	if runtime.GOOS == "windows" {
		return "cmd", []string{"/d", "/s", "/c", command}
	}
	return "sh", []string{"-lc", command}
}

func boolEnv(key string) bool {
	return trustWorkspaceEnv(key, false)
}
func sanitizeSyncPathspecs(values []string) []string {
	seen := make(map[string]struct{})
	result := make([]string, 0, len(values))
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			continue
		}
		if _, ok := seen[trimmed]; ok {
			continue
		}
		seen[trimmed] = struct{}{}
		result = append(result, trimmed)
	}
	sort.Strings(result)
	return result
}

func trustWorkspaceEnv(key string, fallback bool) bool {
	value := strings.ToLower(strings.TrimSpace(os.Getenv(key)))
	if value == "" {
		return fallback
	}
	switch value {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func ensureCursorAgentTrustFlag(args []string, enabled bool) []string {
	if !enabled {
		return append([]string{}, args...)
	}
	for _, arg := range args {
		if arg == "--trust" {
			return append([]string{}, args...)
		}
	}
	out := append([]string{}, args...)
	out = append(out, "--trust")
	return out
}

func defaultCursorAgentModel() string {
	model := strings.TrimSpace(os.Getenv("CURSOR_AGENT_MODEL"))
	if model == "" {
		return "auto"
	}
	return model
}

func ensureCursorAgentModelArg(args []string, model string) []string {
	model = strings.TrimSpace(model)
	if model == "" {
		return append([]string{}, args...)
	}
	out := make([]string, 0, len(args)+2)
	for index := 0; index < len(args); index++ {
		arg := args[index]
		if arg == "--model" {
			index++
			continue
		}
		if strings.HasPrefix(arg, "--model=") {
			continue
		}
		out = append(out, arg)
	}
	out = append(out, "--model", model)
	return out
}

func withCursorAgentModelArg(args []string, model string) []string {
	return ensureCursorAgentModelArg(args, model)
}

func defaultWSLExecutable(current string) string {
	if strings.TrimSpace(current) == "" || strings.EqualFold(strings.TrimSpace(current), "cursor-agent") {
		return "wsl.exe"
	}
	return current
}

type resolvedWSLCursorAgent struct {
	Distro string
	Binary string
}

func resolveWSLCursorAgent(wslBin, requested string) (resolvedWSLCursorAgent, error) {
	if requested != "" {
		return resolveWSLCursorAgentInDistro(wslBin, requested)
	}

	resolved, err := resolveWSLCursorAgentInDistro(wslBin, "")
	if err == nil {
		return resolved, nil
	}

	distros, listErr := listWSLDistros(wslBin)
	if listErr != nil {
		return resolvedWSLCursorAgent{}, listErr
	}
	for _, distro := range distros {
		if distro == "" {
			continue
		}
		resolved, distroErr := resolveWSLCursorAgentInDistro(wslBin, distro)
		if distroErr == nil {
			return resolved, nil
		}
	}
	return resolvedWSLCursorAgent{}, errors.New("cursor-agent was not found in any WSL distro; set CURSOR_AGENT_WSL_DISTRO")
}

func resolveWSLCursorAgentInDistro(wslBin, distro string) (resolvedWSLCursorAgent, error) {
	homeDir, err := wslPrintenv(wslBin, distro, "HOME")
	if err != nil {
		return resolvedWSLCursorAgent{}, err
	}
	for _, candidate := range []string{
		path.Join(homeDir, ".local", "bin", "cursor-agent"),
		path.Join(homeDir, ".local", "bin", "agent"),
	} {
		if wslBinaryAvailable(wslBin, distro, candidate) {
			return resolvedWSLCursorAgent{Distro: distro, Binary: candidate}, nil
		}
	}
	if distro == "" {
		return resolvedWSLCursorAgent{}, errors.New("cursor-agent was not found in the default WSL distro")
	}
	return resolvedWSLCursorAgent{}, fmt.Errorf("cursor-agent was not found in WSL distro %q", distro)
}

func wslBinaryAvailable(wslBin, distro, linuxBinary string) bool {
	_, _, err := runCommand(
		context.Background(),
		"",
		nil,
		nil,
		wslBin,
		append(buildWSLBaseArgs(distro), linuxBinary, "--version")...,
	)
	return err == nil
}

func wslPrintenv(wslBin, distro, key string) (string, error) {
	stdout, stderr, err := runCommand(context.Background(), "", nil, nil, wslBin, append(buildWSLBaseArgs(distro), "printenv", key)...)
	if err != nil {
		message := normalizeWSLOutput(strings.Join(nonEmptyStrings(stdout, stderr), "\n"))
		if message == "" {
			message = err.Error()
		}
		return "", fmt.Errorf("read WSL environment %s: %s", key, compactMessage(message))
	}
	value := strings.TrimSpace(normalizeWSLOutput(stdout))
	if value == "" {
		return "", fmt.Errorf("WSL environment %s is empty", key)
	}
	return value, nil
}

func listWSLDistros(wslBin string) ([]string, error) {
	stdout, stderr, err := runCommand(context.Background(), "", nil, nil, wslBin, "-l", "-q")
	if err != nil {
		message := normalizeWSLOutput(strings.Join(nonEmptyStrings(stdout, stderr), "\n"))
		if message == "" {
			message = err.Error()
		}
		return nil, fmt.Errorf("list WSL distros: %s", compactMessage(message))
	}

	raw := normalizeWSLOutput(strings.Join(nonEmptyStrings(stdout, stderr), "\n"))
	seen := make(map[string]struct{})
	distros := make([]string, 0)
	for _, line := range strings.Split(raw, "\n") {
		distro := strings.TrimSpace(line)
		if distro == "" {
			continue
		}
		if _, ok := seen[distro]; ok {
			continue
		}
		seen[distro] = struct{}{}
		distros = append(distros, distro)
	}
	return distros, nil
}

func normalizeWSLOutput(value string) string {
	return strings.ReplaceAll(value, "\x00", "")
}

func buildWSLBaseArgs(distro string) []string {
	args := make([]string, 0, 3)
	if distro != "" {
		args = append(args, "-d", distro)
	}
	args = append(args, "--")
	return args
}

func buildWSLCursorAgentArgs(distro, linuxBinary string, cursorAgentArgs []string) []string {
	args := append(buildWSLBaseArgs(distro), linuxBinary)
	args = append(args, cursorAgentArgs...)
	return args
}

func wslCursorAgentNote(distro string) string {
	if distro == "" {
		return "cursor-agent is invoked through the default WSL distro"
	}
	return "cursor-agent is invoked through WSL distro: " + distro
}
