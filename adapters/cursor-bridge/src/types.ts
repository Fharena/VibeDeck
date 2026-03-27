export interface AdapterCapabilities {
  supportsPartialApply: boolean;
  supportsStructuredPatch: boolean;
  supportsContextSelection: boolean;
  supportsArtifacts: boolean;
  supportsOpenLocation: boolean;
}

export interface ContextOptions {
  includeActiveFile: boolean;
  includeSelection: boolean;
  includeLatestError: boolean;
  includeWorkspaceSummary: boolean;
}

export interface WorkspaceContext {
  activeFilePath?: string;
  selection?: string;
  latestTerminalError?: string;
  changedFiles: string[];
  lastRunProfile?: string;
  lastRunStatus?: string;
}

export interface ContextRequest {
  options: ContextOptions;
}

export interface SubmitTaskInput {
  prompt: string;
  template?: string;
  model?: string;
  reasoningLevel?: string;
  context: WorkspaceContext;
}

export interface ProviderVisibleEvent {
  kind?: string;
  role?: string;
  title?: string;
  body?: string;
  data?: Record<string, unknown>;
}

export interface TaskHandle {
  taskId: string;
  providerEvents?: ProviderVisibleEvent[];
}

export interface Hunk {
  hunkId: string;
  header: string;
  diff: string;
  risk?: "low" | "medium" | "high";
}

export interface FilePatch {
  path: string;
  status: "added" | "modified" | "deleted" | "renamed";
  hunks: Hunk[];
}

export interface PatchBundle {
  jobId: string;
  summary: string;
  files: FilePatch[];
}

export interface ApplyPatchInput {
  taskId: string;
  mode: "all" | "selected";
  selected?: Array<{
    path: string;
    hunkIds: string[];
  }>;
}

export interface ApplyPatchResult {
  status: "success" | "partial" | "conflict" | "failed";
  message: string;
}

export interface RunProfileInput {
  taskId: string;
  jobId: string;
  profileId: string;
  command: string;
}

export interface RunHandle {
  runId: string;
}

export interface ParsedError {
  message: string;
  path?: string;
  line?: number;
  column?: number;
}

export interface RunResult {
  runId: string;
  profileId: string;
  status: "passed" | "failed" | "partial" | "running";
  summary: string;
  topErrors: ParsedError[];
  excerpt?: string;
  providerEvents?: ProviderVisibleEvent[];
}

export interface OpenLocationInput {
  path: string;
  line: number;
  column?: number;
}

export interface WorkspaceAdapter {
  name(): string;
  capabilities(): AdapterCapabilities;
  getContext(input: ContextRequest): Promise<WorkspaceContext>;
  submitTask(input: SubmitTaskInput): Promise<TaskHandle>;
  getPatch(taskId: string): Promise<PatchBundle | null>;
  applyPatch(input: ApplyPatchInput): Promise<ApplyPatchResult>;
  runProfile(input: RunProfileInput): Promise<RunHandle>;
  getRunResult(runId: string): Promise<RunResult | null>;
  openLocation(input: OpenLocationInput): Promise<void>;
}
