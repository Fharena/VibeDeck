import type {
  CursorBridgeCommands,
  CursorCommandHost,
  CursorWorkspaceMetadata,
} from "./cursorHost.js";
import type {
  AdapterCapabilities,
  ApplyPatchInput,
  ApplyPatchResult,
  ContextRequest,
  FilePatch,
  Hunk,
  OpenLocationInput,
  ParsedError,
  ProviderVisibleEvent,
  PatchBundle,
  RunHandle,
  RunProfileInput,
  RunResult,
  SubmitTaskInput,
  TaskHandle,
  WorkspaceAdapter,
  WorkspaceContext,
} from "./types.js";

const PATCH_STATUSES = new Set<FilePatch["status"]>(["added", "modified", "deleted", "renamed"]);
const HUNK_RISKS = new Set<NonNullable<Hunk["risk"]>>(["low", "medium", "high"]);
const APPLY_STATUSES = new Set<ApplyPatchResult["status"]>([
  "success",
  "partial",
  "conflict",
  "failed",
]);
const RUN_STATUSES = new Set<RunResult["status"]>(["passed", "failed", "partial", "running"]);

export const defaultCursorBridgeCommands: CursorBridgeCommands = {
  submitTask: "vibedeck.submitTask",
  getPatch: "vibedeck.getPatch",
  applyPatch: "vibedeck.applyPatch",
  runProfile: "vibedeck.runProfile",
  getRunResult: "vibedeck.getRunResult",
  getWorkspaceMetadata: "vibedeck.getWorkspaceMetadata",
  getLatestTerminalError: "vibedeck.getLatestTerminalError",
};

const defaultCapabilities: AdapterCapabilities = {
  supportsPartialApply: true,
  supportsStructuredPatch: true,
  supportsContextSelection: true,
  supportsArtifacts: false,
  supportsOpenLocation: true,
};

export interface CursorExtensionBridgeOptions {
  host: CursorCommandHost;
  commands?: Partial<CursorBridgeCommands>;
  capabilities?: Partial<AdapterCapabilities>;
}

export function createCursorExtensionBridge(
  options: CursorExtensionBridgeOptions,
): CursorExtensionBridge {
  return new CursorExtensionBridge(options);
}

export class CursorExtensionBridge implements WorkspaceAdapter {
  private readonly host: CursorCommandHost;
  private readonly commands: CursorBridgeCommands;
  private readonly resolvedCapabilities: AdapterCapabilities;

  constructor(options: CursorExtensionBridgeOptions) {
    this.host = options.host;
    this.commands = {
      ...defaultCursorBridgeCommands,
      ...options.commands,
    };
    this.resolvedCapabilities = {
      ...defaultCapabilities,
      ...options.capabilities,
    };
  }

  name(): string {
    return "cursor-extension-bridge";
  }

  capabilities(): AdapterCapabilities {
    return this.resolvedCapabilities;
  }

  async getContext(input: ContextRequest): Promise<WorkspaceContext> {
    const shouldReadActiveEditor = input.options.includeActiveFile || input.options.includeSelection;
    const shouldReadWorkspaceMetadata =
      this.commands.getWorkspaceMetadata !== undefined &&
      (input.options.includeWorkspaceSummary || input.options.includeLatestError);
    const shouldReadChangedFiles = input.options.includeWorkspaceSummary;
    const shouldReadLatestTerminalError = input.options.includeLatestError;

    const [activeEditor, workspaceMetadata, changedFiles, latestTerminalError] = await Promise.all([
      shouldReadActiveEditor
        ? this.host.getActiveEditor().catch(() => null)
        : Promise.resolve(null),
      shouldReadWorkspaceMetadata ? this.readWorkspaceMetadata() : Promise.resolve<CursorWorkspaceMetadata>({}),
      shouldReadChangedFiles
        ? this.host.getChangedFiles().catch(() => [])
        : Promise.resolve([]),
      shouldReadLatestTerminalError ? this.readLatestTerminalError() : Promise.resolve(undefined),
    ]);

    const mergedChangedFiles = input.options.includeWorkspaceSummary
      ? dedupeStrings(workspaceMetadata.changedFiles ?? changedFiles)
      : [];

    return {
      activeFilePath: input.options.includeActiveFile ? activeEditor?.filePath : undefined,
      selection: input.options.includeSelection ? activeEditor?.selection : undefined,
      latestTerminalError: input.options.includeLatestError
        ? workspaceMetadata.latestTerminalError ?? latestTerminalError
        : undefined,
      changedFiles: mergedChangedFiles,
      lastRunProfile: input.options.includeWorkspaceSummary
        ? workspaceMetadata.lastRunProfile
        : undefined,
      lastRunStatus: input.options.includeWorkspaceSummary
        ? workspaceMetadata.lastRunStatus
        : undefined,
    };
  }

  async submitTask(input: SubmitTaskInput): Promise<TaskHandle> {
    const result = await this.host.executeCommand(this.commands.submitTask, input);
    return normalizeTaskHandle(result);
  }

  async getPatch(taskId: string): Promise<PatchBundle | null> {
    const result = await this.host.executeCommand(this.commands.getPatch, taskId);
    return normalizePatchBundle(result);
  }

  async applyPatch(input: ApplyPatchInput): Promise<ApplyPatchResult> {
    const result = await this.host.executeCommand(this.commands.applyPatch, input);
    return normalizeApplyPatchResult(result);
  }

  async runProfile(input: RunProfileInput): Promise<RunHandle> {
    const result = await this.host.executeCommand(this.commands.runProfile, input);
    return normalizeRunHandle(result);
  }

  async getRunResult(runId: string): Promise<RunResult | null> {
    const result = await this.host.executeCommand(this.commands.getRunResult, runId);
    return normalizeRunResult(result);
  }

  async openLocation(input: OpenLocationInput): Promise<void> {
    if (this.commands.openLocation) {
      await this.host.executeCommand(this.commands.openLocation, input);
      return;
    }

    await this.host.openLocation(input);
  }

  private async readWorkspaceMetadata(): Promise<CursorWorkspaceMetadata> {
    try {
      const result = await this.host.executeCommand(this.commands.getWorkspaceMetadata!);
      return normalizeWorkspaceMetadata(result);
    } catch {
      return {};
    }
  }

  private async readLatestTerminalError(): Promise<string | undefined> {
    if (!this.commands.getLatestTerminalError) {
      return undefined;
    }

    try {
      const result = await this.host.executeCommand(this.commands.getLatestTerminalError);
      return typeof result === "string" && result.length > 0 ? result : undefined;
    } catch {
      return undefined;
    }
  }
}

function normalizeTaskHandle(value: unknown): TaskHandle {
  if (typeof value === "string" && value.length > 0) {
    return { taskId: value };
  }

  const record = asRecord(value, "TaskHandle");
  const taskId = readRequiredString(record.taskId, "TaskHandle.taskId");
  return {
    taskId,
    providerEvents: normalizeProviderVisibleEvents(record.providerEvents, "TaskHandle.providerEvents"),
  };
}

function normalizePatchBundle(value: unknown): PatchBundle | null {
  if (value === null || value === undefined) {
    return null;
  }

  const record = asRecord(value, "PatchBundle");
  const files = readArray(record.files, "PatchBundle.files").map((item, index) =>
    normalizeFilePatch(item, `PatchBundle.files[${index}]`),
  );

  return {
    jobId: readOptionalString(record.jobId) ?? "",
    summary: readOptionalString(record.summary) ?? "",
    files,
  };
}

function normalizeFilePatch(value: unknown, label: string): FilePatch {
  const record = asRecord(value, label);
  const status = readRequiredString(record.status, `${label}.status`);
  if (!PATCH_STATUSES.has(status as FilePatch["status"])) {
    throw new Error(`invalid ${label}.status`);
  }

  const hunks = readArray(record.hunks, `${label}.hunks`).map((item, index) =>
    normalizeHunk(item, `${label}.hunks[${index}]`),
  );

  return {
    path: readRequiredString(record.path, `${label}.path`),
    status: status as FilePatch["status"],
    hunks,
  };
}

function normalizeHunk(value: unknown, label: string): Hunk {
  const record = asRecord(value, label);
  const risk = readOptionalString(record.risk);
  if (risk !== undefined && !HUNK_RISKS.has(risk as NonNullable<Hunk["risk"]>)) {
    throw new Error(`invalid ${label}.risk`);
  }

  return {
    hunkId: readRequiredString(record.hunkId, `${label}.hunkId`),
    header: readRequiredString(record.header, `${label}.header`),
    diff: readRequiredString(record.diff, `${label}.diff`),
    risk: risk as Hunk["risk"],
  };
}

function normalizeApplyPatchResult(value: unknown): ApplyPatchResult {
  if (typeof value === "string" && APPLY_STATUSES.has(value as ApplyPatchResult["status"])) {
    return { status: value as ApplyPatchResult["status"], message: value };
  }

  const record = asRecord(value, "ApplyPatchResult");
  const status = readRequiredString(record.status, "ApplyPatchResult.status");
  if (!APPLY_STATUSES.has(status as ApplyPatchResult["status"])) {
    throw new Error("invalid ApplyPatchResult.status");
  }

  return {
    status: status as ApplyPatchResult["status"],
    message: readOptionalString(record.message) ?? status,
  };
}

function normalizeRunHandle(value: unknown): RunHandle {
  if (typeof value === "string" && value.length > 0) {
    return { runId: value };
  }

  const record = asRecord(value, "RunHandle");
  const runId = readRequiredString(record.runId, "RunHandle.runId");
  return { runId };
}

function normalizeRunResult(value: unknown): RunResult | null {
  if (value === null || value === undefined) {
    return null;
  }

  const record = asRecord(value, "RunResult");
  const status = readRequiredString(record.status, "RunResult.status");
  if (!RUN_STATUSES.has(status as RunResult["status"])) {
    throw new Error("invalid RunResult.status");
  }

  const topErrors = readArray(record.topErrors, "RunResult.topErrors").map((item, index) =>
    normalizeParsedError(item, `RunResult.topErrors[${index}]`),
  );

  return {
    runId: readRequiredString(record.runId, "RunResult.runId"),
    profileId: readRequiredString(record.profileId, "RunResult.profileId"),
    status: status as RunResult["status"],
    summary: readRequiredString(record.summary, "RunResult.summary"),
    topErrors,
    excerpt: readOptionalString(record.excerpt),
    providerEvents: normalizeProviderVisibleEvents(record.providerEvents, "RunResult.providerEvents"),
  };
}

function normalizeProviderVisibleEvents(value: unknown, label: string): ProviderVisibleEvent[] | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }

  return readArray(value, label).map((item, index) => normalizeProviderVisibleEvent(item, `${label}[${index}]`));
}

function normalizeProviderVisibleEvent(value: unknown, label: string): ProviderVisibleEvent {
  const record = asRecord(value, label);
  return {
    kind: readOptionalString(record.kind),
    role: readOptionalString(record.role),
    title: readOptionalString(record.title),
    body: readOptionalString(record.body),
    data: readOptionalRecord(record.data),
  };
}

function normalizeParsedError(value: unknown, label: string): ParsedError {
  const record = asRecord(value, label);
  return {
    message: readRequiredString(record.message, `${label}.message`),
    path: readOptionalString(record.path),
    line: readOptionalNumber(record.line),
    column: readOptionalNumber(record.column),
  };
}

function normalizeWorkspaceMetadata(value: unknown): CursorWorkspaceMetadata {
  const record = asRecord(value, "CursorWorkspaceMetadata");
  return {
    changedFiles: Array.isArray(record.changedFiles)
      ? record.changedFiles.filter((item): item is string => typeof item === "string")
      : undefined,
    lastRunProfile: readOptionalString(record.lastRunProfile),
    lastRunStatus: readOptionalString(record.lastRunStatus),
    latestTerminalError: readOptionalString(record.latestTerminalError),
  };
}

function asRecord(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`invalid ${label}`);
  }

  return value as Record<string, unknown>;
}

function readArray(value: unknown, label: string): unknown[] {
  if (!Array.isArray(value)) {
    throw new Error(`invalid ${label}`);
  }

  return value;
}

function readRequiredString(value: unknown, label: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`invalid ${label}`);
  }

  return value;
}

function readOptionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function readOptionalNumber(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return undefined;
  }

  return Math.trunc(value);
}

function readOptionalRecord(value: unknown): Record<string, unknown> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

function dedupeStrings(values: string[]): string[] {
  return [...new Set(values)];
}
