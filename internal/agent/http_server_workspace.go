package agent

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

const maxWorkspaceFileSizeBytes int64 = 1024 * 1024

var skippedWorkspaceDirs = map[string]struct{}{
	".git":         {},
	".dart_tool":   {},
	"node_modules": {},
	"build":        {},
	"dist":         {},
	"coverage":     {},
}

type WorkspaceTreeEntry struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	IsDir     bool   `json:"isDir"`
	GitStatus string `json:"gitStatus,omitempty"`
	IsActive  bool   `json:"isActive,omitempty"`
	IsChanged bool   `json:"isChanged,omitempty"`
	IsPatch   bool   `json:"isPatch,omitempty"`
	HasError  bool   `json:"hasError,omitempty"`
}

type WorkspaceTreeResponse struct {
	RootPath string               `json:"rootPath"`
	Path     string               `json:"path,omitempty"`
	Entries  []WorkspaceTreeEntry `json:"entries"`
}

type WorkspaceFileResponse struct {
	Path       string `json:"path"`
	Content    string `json:"content"`
	GitStatus  string `json:"gitStatus,omitempty"`
	SizeBytes  int64  `json:"sizeBytes"`
	UpdatedAt  int64  `json:"updatedAt"`
	IsWritable bool   `json:"isWritable"`
}

type WorkspaceFileUpdateRequest struct {
	Content string `json:"content"`
}

type sessionWorkspaceHints struct {
	activePath   string
	runErrorPath string
	changedFiles map[string]struct{}
	patchFiles   map[string]struct{}
}

func (s *HTTPServer) handleWorkspaceTree(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}

	rootPath := s.workspaceRootPath()
	if rootPath == "" {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "workspace root is not configured"})
		return
	}

	relativePath := cleanWorkspaceRelativePath(r.URL.Query().Get("path"))
	absolutePath, err := resolveWorkspacePath(rootPath, relativePath)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid workspace path"})
		return
	}

	info, err := os.Stat(absolutePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "workspace path not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to inspect workspace path"})
		return
	}
	if !info.IsDir() {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "workspace path must be a directory"})
		return
	}

	hints := s.sessionWorkspaceHints(r.URL.Query().Get("sessionId"))
	gitStatuses := readGitStatusMap(r.Context(), rootPath, relativePath)
	entries, err := listWorkspaceTreeEntries(absolutePath, relativePath, gitStatuses, hints)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to read workspace directory"})
		return
	}

	writeJSON(w, http.StatusOK, WorkspaceTreeResponse{
		RootPath: filepath.ToSlash(rootPath),
		Path:     relativePath,
		Entries:  entries,
	})
}

func (s *HTTPServer) handleWorkspaceFile(w http.ResponseWriter, r *http.Request) {
	rootPath := s.workspaceRootPath()
	if rootPath == "" {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "workspace root is not configured"})
		return
	}

	relativePath := cleanWorkspaceRelativePath(r.URL.Query().Get("path"))
	if relativePath == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "file path is required"})
		return
	}

	absolutePath, err := resolveWorkspacePath(rootPath, relativePath)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid file path"})
		return
	}

	switch r.Method {
	case http.MethodGet:
		response, status, err := readWorkspaceFile(r.Context(), rootPath, relativePath, absolutePath)
		if err != nil {
			writeJSON(w, status, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, response)
	case http.MethodPut:
		var req WorkspaceFileUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid workspace file update request"})
			return
		}

		response, status, err := writeWorkspaceFile(r.Context(), rootPath, relativePath, absolutePath, req.Content)
		if err != nil {
			writeJSON(w, status, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, response)
	default:
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
	}
}

func (s *HTTPServer) workspaceRootPath() string {
	info := BasicAdapterRuntimeInfo(s.adapter)
	if provider, ok := s.adapter.(AdapterRuntimeInfoProvider); ok {
		info = provider.RuntimeInfo()
	}
	return strings.TrimSpace(info.WorkspaceRoot)
}

func (s *HTTPServer) sessionWorkspaceHints(sessionID string) sessionWorkspaceHints {
	detail, ok := s.sessionDetail(strings.TrimSpace(sessionID))
	if !ok {
		return sessionWorkspaceHints{
			changedFiles: map[string]struct{}{},
			patchFiles:   map[string]struct{}{},
		}
	}

	changedFiles := make(map[string]struct{})
	for _, path := range detail.LiveState.Workspace.ChangedFiles {
		normalized := cleanWorkspaceRelativePath(path)
		if normalized != "" {
			changedFiles[normalized] = struct{}{}
		}
	}
	for _, path := range detail.OperationState.RunChangedFiles {
		normalized := cleanWorkspaceRelativePath(path)
		if normalized != "" {
			changedFiles[normalized] = struct{}{}
		}
	}
	for _, path := range detail.OperationState.CurrentJobFiles {
		normalized := cleanWorkspaceRelativePath(path)
		if normalized != "" {
			changedFiles[normalized] = struct{}{}
		}
	}

	patchFiles := make(map[string]struct{})
	for _, path := range detail.LiveState.Workspace.PatchFiles {
		normalized := cleanWorkspaceRelativePath(path)
		if normalized != "" {
			patchFiles[normalized] = struct{}{}
		}
	}
	for _, path := range detail.OperationState.PatchFiles {
		normalized := cleanWorkspaceRelativePath(path)
		if normalized != "" {
			patchFiles[normalized] = struct{}{}
		}
	}

	return sessionWorkspaceHints{
		activePath:   cleanWorkspaceRelativePath(firstNonEmpty(detail.LiveState.Focus.ActiveFilePath, detail.LiveState.Workspace.ActiveFilePath)),
		runErrorPath: cleanWorkspaceRelativePath(detail.LiveState.Focus.RunErrorPath),
		changedFiles: changedFiles,
		patchFiles:   patchFiles,
	}
}

func listWorkspaceTreeEntries(
	absolutePath string,
	relativePath string,
	gitStatuses map[string]string,
	hints sessionWorkspaceHints,
) ([]WorkspaceTreeEntry, error) {
	items, err := os.ReadDir(absolutePath)
	if err != nil {
		return nil, err
	}

	entries := make([]WorkspaceTreeEntry, 0, len(items))
	for _, item := range items {
		name := strings.TrimSpace(item.Name())
		if name == "" {
			continue
		}
		if item.IsDir() {
			if _, skipped := skippedWorkspaceDirs[name]; skipped {
				continue
			}
		}

		entryPath := name
		if relativePath != "" {
			entryPath = relativePath + "/" + name
		}
		entryPath = filepath.ToSlash(entryPath)

		_, isChanged := hints.changedFiles[entryPath]
		_, isPatch := hints.patchFiles[entryPath]

		entries = append(entries, WorkspaceTreeEntry{
			Name:      name,
			Path:      entryPath,
			IsDir:     item.IsDir(),
			GitStatus: gitStatuses[entryPath],
			IsActive:  entryPath == hints.activePath,
			IsChanged: isChanged,
			IsPatch:   isPatch,
			HasError:  entryPath == hints.runErrorPath,
		})
	}

	sort.Slice(entries, func(i, j int) bool {
		if entries[i].IsDir != entries[j].IsDir {
			return entries[i].IsDir
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
	return entries, nil
}

func readWorkspaceFile(
	ctx context.Context,
	rootPath string,
	relativePath string,
	absolutePath string,
) (WorkspaceFileResponse, int, error) {
	info, err := os.Stat(absolutePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return WorkspaceFileResponse{}, http.StatusNotFound, errors.New("workspace file not found")
		}
		return WorkspaceFileResponse{}, http.StatusInternalServerError, errors.New("failed to inspect workspace file")
	}
	if info.IsDir() {
		return WorkspaceFileResponse{}, http.StatusBadRequest, errors.New("workspace file path must point to a file")
	}
	if info.Size() > maxWorkspaceFileSizeBytes {
		return WorkspaceFileResponse{}, http.StatusRequestEntityTooLarge, errors.New("workspace file is too large for mobile preview")
	}

	content, err := os.ReadFile(absolutePath)
	if err != nil {
		return WorkspaceFileResponse{}, http.StatusInternalServerError, errors.New("failed to read workspace file")
	}
	if !utf8.Valid(content) || strings.ContainsRune(string(content), '\x00') {
		return WorkspaceFileResponse{}, http.StatusUnsupportedMediaType, errors.New("binary files are not supported in mobile preview")
	}

	gitStatuses := readGitStatusMap(ctx, rootPath, relativePath)
	return WorkspaceFileResponse{
		Path:       filepath.ToSlash(relativePath),
		Content:    string(content),
		GitStatus:  gitStatuses[relativePath],
		SizeBytes:  info.Size(),
		UpdatedAt:  info.ModTime().UnixMilli(),
		IsWritable: info.Mode().Perm()&0o200 != 0,
	}, http.StatusOK, nil
}

func writeWorkspaceFile(
	ctx context.Context,
	rootPath string,
	relativePath string,
	absolutePath string,
	content string,
) (WorkspaceFileResponse, int, error) {
	mode := os.FileMode(0o644)
	if info, err := os.Stat(absolutePath); err == nil {
		if info.IsDir() {
			return WorkspaceFileResponse{}, http.StatusBadRequest, errors.New("workspace file path must point to a file")
		}
		mode = info.Mode().Perm()
	}

	if err := os.WriteFile(absolutePath, []byte(content), mode); err != nil {
		return WorkspaceFileResponse{}, http.StatusInternalServerError, errors.New("failed to save workspace file")
	}

	return readWorkspaceFile(ctx, rootPath, relativePath, absolutePath)
}

func cleanWorkspaceRelativePath(value string) string {
	trimmed := strings.TrimSpace(strings.ReplaceAll(value, "\\", "/"))
	trimmed = strings.TrimPrefix(trimmed, "/")
	if trimmed == "" || trimmed == "." {
		return ""
	}

	clean := filepath.ToSlash(filepath.Clean(trimmed))
	clean = strings.TrimPrefix(clean, "./")
	clean = strings.TrimPrefix(clean, "/")
	if clean == "." {
		return ""
	}
	return clean
}

func resolveWorkspacePath(rootPath string, relativePath string) (string, error) {
	absoluteRoot, err := filepath.Abs(rootPath)
	if err != nil {
		return "", err
	}

	target := absoluteRoot
	if relativePath != "" {
		target = filepath.Join(absoluteRoot, filepath.FromSlash(relativePath))
	}
	absoluteTarget, err := filepath.Abs(target)
	if err != nil {
		return "", err
	}

	relativeTarget, err := filepath.Rel(absoluteRoot, absoluteTarget)
	if err != nil {
		return "", err
	}
	if relativeTarget == ".." || strings.HasPrefix(relativeTarget, ".."+string(os.PathSeparator)) {
		return "", errors.New("path escapes workspace root")
	}
	return absoluteTarget, nil
}

func readGitStatusMap(ctx context.Context, rootPath string, relativePath string) map[string]string {
	args := []string{"-C", rootPath, "status", "--porcelain=1", "--untracked-files=all", "--ignored=no"}
	if relativePath != "" {
		args = append(args, "--", filepath.FromSlash(relativePath))
	}

	output, err := exec.CommandContext(ctx, "git", args...).Output()
	if err != nil {
		return map[string]string{}
	}

	statuses := make(map[string]string)
	lines := strings.Split(strings.ReplaceAll(string(output), "\r\n", "\n"), "\n")
	for _, line := range lines {
		line = strings.TrimRight(line, "\n")
		if len(line) < 4 {
			continue
		}

		code := strings.TrimSpace(line[:2])
		pathPart := strings.TrimSpace(line[3:])
		if pathPart == "" {
			continue
		}
		if arrow := strings.Index(pathPart, " -> "); arrow >= 0 {
			pathPart = strings.TrimSpace(pathPart[arrow+4:])
		}

		normalizedPath := filepath.ToSlash(pathPart)
		statuses[normalizedPath] = normalizeGitStatus(code)
	}
	return statuses
}

func normalizeGitStatus(code string) string {
	code = strings.TrimSpace(code)
	switch code {
	case "??":
		return "U"
	case "!!":
		return ""
	}

	for _, candidate := range code {
		switch candidate {
		case 'M', 'A', 'D', 'R', 'C', 'U':
			return string(candidate)
		}
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed != "" {
			return trimmed
		}
	}
	return ""
}
