import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  type AdapterCapabilities,
  type ApplyPatchInput,
  type ApplyPatchResult,
  type ContextRequest,
  type FilePatch,
  type OpenLocationInput,
  type ProviderVisibleEvent,
  type PatchBundle,
  type RunHandle,
  type RunProfileInput,
  type RunResult,
  type SubmitTaskInput,
  type TaskHandle,
  type WorkspaceAdapter,
  type WorkspaceContext,
} from "@vibedeck/cursor-bridge";

export interface CursorAgentCommandAdapterConfig {
  workspaceRoot?: string;
  tempRoot?: string;
  gitBin: string;
  cursorAgentBin: string;
  cursorAgentArgs: string[];
  cursorAgentEnv: string[];
  syncIgnoredPaths: string[];
  useWsl: boolean;
  wslDistro?: string;
  promptTimeoutMs: number;
  runTimeoutMs: number;
}

interface ResolvedCursorAgentCommandAdapterConfig extends CursorAgentCommandAdapterConfig {
  workspaceRoot: string;
  tempRoot: string;
}

interface CursorAgentTask {
  taskId: string;
  prompt: string;
  summary: string;
  rawDiff: string;
  parsed: UnifiedPatch;
  patch: PatchBundle;
  providerEvents: ProviderVisibleEvent[];
  createdAt: string;
}

interface UnifiedPatch {
  files: UnifiedPatchFile[];
}

interface UnifiedPatchFile {
  path: string;
  status: FilePatch["status"];
  headerLines: string[];
  hunks: UnifiedPatchHunk[];
}

interface UnifiedPatchHunk {
  hunkId: string;
  header: string;
  lines: string[];
}

interface CursorAgentJSONOutput {
  type?: string;
  result?: string;
  text?: string;
  output?: string;
  summary?: string;
  message?: string;
}

interface CommandResult {
  stdout: string;
  stderr: string;
}

interface CommandOptions {
  cwd?: string;
  env?: Record<string, string>;
  stdin?: string;
  timeoutMs?: number;
}

const PATCH_STATUSES = new Set<FilePatch["status"]>(["added", "modified", "deleted", "renamed"]);

export async function createCursorAgentCommandAdapter(
  config: CursorAgentCommandAdapterConfig,
): Promise<CursorAgentCommandAdapter> {
  const workspaceHint = config.workspaceRoot?.trim() || process.cwd();
  const tempRoot = config.tempRoot?.trim() || tmpdir();
  await mkdir(tempRoot, { recursive: true });
  const workspaceRoot = await readGitTopLevel(config.gitBin, workspaceHint);
  return new CursorAgentCommandAdapter({
    ...config,
    workspaceRoot,
    tempRoot,
    syncIgnoredPaths: sanitizeSyncPathspecs(config.syncIgnoredPaths ?? []),
  });
}

export class CursorAgentCommandAdapter implements WorkspaceAdapter {
  private readonly config: ResolvedCursorAgentCommandAdapterConfig;
  private taskSeq = 0;
  private runSeq = 0;
  private readonly tasks = new Map<string, CursorAgentTask>();
  private readonly runs = new Map<string, RunResult>();
  private lastRunProfile?: string;
  private lastRunStatus?: string;
  private latestTerminalError?: string;

  constructor(config: ResolvedCursorAgentCommandAdapterConfig) {
    this.config = config;
  }

  name(): string {
    return "cursor-agent-command-provider";
  }

  capabilities(): AdapterCapabilities {
    return {
      supportsPartialApply: true,
      supportsStructuredPatch: true,
      supportsContextSelection: false,
      supportsArtifacts: false,
      supportsOpenLocation: false,
    };
  }

  async getContext(input: ContextRequest): Promise<WorkspaceContext> {
    const changedFiles = input.options.includeWorkspaceSummary ? await this.listChangedFiles() : [];
    return {
      changedFiles,
      lastRunProfile: input.options.includeWorkspaceSummary ? this.lastRunProfile : undefined,
      lastRunStatus: input.options.includeWorkspaceSummary ? this.lastRunStatus : undefined,
      latestTerminalError: input.options.includeLatestError ? this.latestTerminalError : undefined,
    };
  }

  async submitTask(input: SubmitTaskInput): Promise<TaskHandle> {
    this.taskSeq += 1;
    const taskId = `task_${this.taskSeq}`;
    const task = await this.generateTask(taskId, input);
    this.tasks.set(taskId, task);
    return {
      taskId,
      providerEvents: task.providerEvents.map((event) => cloneProviderVisibleEvent(event)),
    };
  }

  async getPatch(taskId: string): Promise<PatchBundle | null> {
    return this.tasks.get(taskId)?.patch ?? null;
  }

  async applyPatch(input: ApplyPatchInput): Promise<ApplyPatchResult> {
    const task = this.tasks.get(input.taskId);
    if (!task) {
      return { status: "failed", message: "task not found" };
    }

    const { patchText, selectedCount } = buildPatchForApply(task, input);
    if (patchText.trim().length === 0) {
      return { status: "success", message: "no patch changes to apply" };
    }

    try {
      await this.runGit(
        this.config.workspaceRoot,
        ["apply", "--check", "--binary", "--whitespace=nowarn"],
        patchText,
      );
    } catch (error) {
      return { status: "conflict", message: asErrorMessage(error) };
    }

    try {
      await this.runGit(
        this.config.workspaceRoot,
        ["apply", "--binary", "--whitespace=nowarn"],
        patchText,
      );
    } catch (error) {
      return { status: "failed", message: asErrorMessage(error) };
    }

    if (input.mode === "selected") {
      return { status: "success", message: `selected hunks applied (${selectedCount})` };
    }
    return { status: "success", message: "patch applied" };
  }

  async runProfile(input: RunProfileInput): Promise<RunHandle> {
    this.runSeq += 1;
    const runId = `run_${input.profileId}_${this.runSeq}`;
    const result = await this.executeRunProfile(runId, input);
    this.runs.set(runId, result);
    this.lastRunProfile = input.profileId;
    this.lastRunStatus = result.status;
    this.latestTerminalError =
      result.status === "passed" ? undefined : firstNonEmptyLine(result.excerpt ?? result.summary);
    return { runId };
  }

  async getRunResult(runId: string): Promise<RunResult | null> {
    return this.runs.get(runId) ?? null;
  }

  async openLocation(_input: OpenLocationInput): Promise<void> {
    return;
  }

  private async generateTask(taskId: string, input: SubmitTaskInput): Promise<CursorAgentTask> {
    const worktreeParent = await mkdtemp(path.join(this.config.tempRoot, "vibedeck-cursor-agent-"));
    const worktreeDir = path.join(worktreeParent, "worktree");
    try {
      await this.runGit(this.config.workspaceRoot, ["worktree", "add", "--detach", worktreeDir]);
      await this.syncWorkspaceIntoWorktree(worktreeDir);
      await this.commitWorktreeBaseline(worktreeDir);

      const prompt = buildCursorAgentPrompt(input);
      const cursorOutput = await this.runCursorAgent(worktreeDir, prompt, input.model);
      const rawDiff = await this.runGit(worktreeDir, ["diff", "--binary", "HEAD", "--", "."]);
      const parsed = parseUnifiedPatch(rawDiff);
      const summary = taskSummary(cursorOutput, parsed);

      const patch = toPatchBundle(parsed, summary);
      return {
        taskId,
        prompt: input.prompt,
        summary,
        rawDiff,
        parsed,
        patch,
        providerEvents: buildProviderVisibleEvents(cursorOutput, patch),
        createdAt: new Date().toISOString(),
      };
    } finally {
      await this.cleanupWorktree(worktreeDir, worktreeParent);
    }
  }

  private async cleanupWorktree(worktreeDir: string, worktreeParent: string): Promise<void> {
    try {
      await this.runGit(this.config.workspaceRoot, ["worktree", "remove", "--force", worktreeDir]);
    } catch {
    }
    try {
      await rm(worktreeParent, { recursive: true, force: true });
    } catch {
    }
  }

  private async listChangedFiles(): Promise<string[]> {
    const output = await this.runGit(this.config.workspaceRoot, [
      "status",
      "--short",
      "--untracked-files=all",
    ]);
    if (output.trim().length === 0) {
      return [];
    }

    const seen = new Set<string>();
    for (const line of normalizeLines(output)) {
      const trimmed = line.trim();
      if (trimmed.length < 3) {
        continue;
      }
      let filePath = trimmed.slice(3).trim();
      const renameSeparator = filePath.lastIndexOf(" -> ");
      if (renameSeparator >= 0) {
        filePath = filePath.slice(renameSeparator + 4).trim();
      }
      if (filePath.length > 0) {
        seen.add(normalizeSlashes(filePath));
      }
    }
    return [...seen].sort();
  }

  private async syncWorkspaceIntoWorktree(worktreeDir: string): Promise<void> {
    const trackedDiff = await this.runGit(this.config.workspaceRoot, ["diff", "--binary", "HEAD", "--", "."]);
    if (trackedDiff.trim().length > 0) {
      await this.runGit(
        worktreeDir,
        ["apply", "--binary", "--whitespace=nowarn"],
        trackedDiff,
      );
    }

    const snapshotFiles = await this.listSnapshotFiles();
    for (const relativePath of snapshotFiles) {
      const sourcePath = path.join(this.config.workspaceRoot, path.normalize(relativePath));
      const targetPath = path.join(worktreeDir, path.normalize(relativePath));
      await copyRegularFile(sourcePath, targetPath);
    }
  }

  private async listSnapshotFiles(): Promise<string[]> {
    const files: string[] = [];
    const seen = new Set<string>();
    const appendOutput = (output: string): void => {
      for (const relativePath of normalizeLines(output)) {
        const trimmed = relativePath.trim();
        if (trimmed.length === 0 || seen.has(trimmed)) {
          continue;
        }
        seen.add(trimmed);
        files.push(trimmed);
      }
    };

    const untrackedOutput = await this.runGit(this.config.workspaceRoot, [
      "ls-files",
      "--others",
      "--exclude-standard",
    ]);
    appendOutput(untrackedOutput);

    if (this.config.syncIgnoredPaths.length > 0) {
      const ignoredOutput = await this.runGit(this.config.workspaceRoot, [
        "ls-files",
        "--others",
        "--ignored",
        "--exclude-standard",
        "--",
        ...this.config.syncIgnoredPaths,
      ]);
      appendOutput(ignoredOutput);
    }

    return files.sort();
  }

  private async commitWorktreeBaseline(worktreeDir: string): Promise<void> {
    const status = await this.runGit(worktreeDir, ["status", "--short", "--untracked-files=all"]);
    if (status.trim().length === 0) {
      return;
    }

    await this.runGit(worktreeDir, ["add", "-A"]);
    await this.runGit(worktreeDir, [
      "-c",
      "user.name=VibeDeck",
      "-c",
      "user.email=vibedeck@example.local",
      "commit",
      "--quiet",
      "-m",
      "vibedeck baseline",
    ]);
  }

  private async runCursorAgent(
    worktreeDir: string,
    prompt: string,
    modelOverride?: string,
  ): Promise<string> {
    const cursorArgs = [...withCursorAgentModelArg(this.config.cursorAgentArgs, modelOverride), prompt];
    if (!this.config.useWsl) {
      const result = await runCommand(this.config.cursorAgentBin, cursorArgs, {
        cwd: worktreeDir,
        env: envEntriesToRecord(this.config.cursorAgentEnv),
        timeoutMs: this.config.promptTimeoutMs,
      });
      return pickCommandOutput(result);
    }

    const wslArgs: string[] = ["--cd", worktreeDir];
    if (this.config.wslDistro?.trim()) {
      wslArgs.push("-d", this.config.wslDistro.trim());
    }
    wslArgs.push("--", this.config.cursorAgentBin, ...cursorArgs);
    const result = await runCommand("wsl.exe", wslArgs, {
      timeoutMs: this.config.promptTimeoutMs,
    });
    return pickCommandOutput(result);
  }

  private async executeRunProfile(runId: string, input: RunProfileInput): Promise<RunResult> {
    if (input.command.trim().length === 0 || input.command === "dynamic") {
      return {
        runId,
        profileId: input.profileId,
        status: "failed",
        summary: "dynamic run profile is not configured for cursor-agent command mode",
        topErrors: [{ message: "dynamic run profile is not configured" }],
        excerpt: "dynamic run profile is not configured",
      };
    }

    const invocation = platformShellCommand(input.command);
    try {
      const result = await runCommand(invocation.command, invocation.args, {
        cwd: this.config.workspaceRoot,
        timeoutMs: this.config.runTimeoutMs,
      });
      const combined = joinNonEmpty(result.stdout, result.stderr).join("\n").trim();
      return {
        runId,
        profileId: input.profileId,
        status: "passed",
        summary: combined.length > 0 ? firstNonEmptyLine(combined) : "command completed successfully",
        topErrors: [],
        excerpt: lastLines(combined, 20),
      };
    } catch (error) {
      const message = asErrorMessage(error);
      return {
        runId,
        profileId: input.profileId,
        status: "failed",
        summary: `command failed: ${compactMessage(message)}`,
        topErrors: [{ message: firstNonEmptyLine(message) || compactMessage(message) }],
        excerpt: lastLines(message, 20),
      };
    }
  }

  private async runGit(dir: string, args: string[], stdin?: string): Promise<string> {
    try {
      const result = await runCommand(this.config.gitBin, args, { cwd: dir, stdin });
      return result.stdout;
    } catch (error) {
      throw new Error(`git ${args.join(" ")} failed: ${compactMessage(asErrorMessage(error))}`);
    }
  }
}

async function readGitTopLevel(gitBin: string, workspaceRoot: string): Promise<string> {
  const result = await runCommand(gitBin, ["rev-parse", "--show-toplevel"], {
    cwd: workspaceRoot,
  });
  const resolved = result.stdout.trim();
  if (resolved.length === 0) {
    throw new Error("git workspace root is empty");
  }
  return resolved;
}

async function runCommand(
  command: string,
  args: string[],
  options: CommandOptions,
): Promise<CommandResult> {
  return await new Promise<CommandResult>((resolve, reject) => {
    const env = options.env ? { ...process.env, ...options.env } : process.env;
    const child = spawn(command, args, {
      cwd: options.cwd,
      env,
      windowsHide: true,
    });

    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;
    const timeout = options.timeoutMs
      ? setTimeout(() => {
          timedOut = true;
          child.kill();
        }, options.timeoutMs)
      : undefined;

    const finish = (callback: () => void): void => {
      if (timeout) {
        clearTimeout(timeout);
      }
      if (settled) {
        return;
      }
      settled = true;
      callback();
    };

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      finish(() => reject(error));
    });
    child.on("close", (code) => {
      finish(() => {
        if (timedOut) {
          reject(new Error(joinNonEmpty(stdout, stderr, `command timed out after ${options.timeoutMs}ms`).join("\n")));
          return;
        }
        if (code === 0) {
          resolve({ stdout, stderr });
          return;
        }
        reject(new Error(joinNonEmpty(stdout, stderr, `exit code ${code ?? "unknown"}`).join("\n")));
      });
    });

    if (options.stdin !== undefined) {
      child.stdin.setDefaultEncoding("utf8");
      child.stdin.write(options.stdin);
    }
    child.stdin.end();
  });
}

function buildCursorAgentPrompt(input: SubmitTaskInput): string {
  const changedFiles = Array.isArray(input.context.changedFiles) ? input.context.changedFiles : [];
  const lines = [
    "You are running inside a disposable VibeDeck git worktree snapshot.",
    "Apply the requested code changes directly to files in this workspace.",
    "Do not create commits, do not rewrite unrelated files, and do not start long-running processes.",
    "Keep the resulting diff as small and reviewable as possible.",
    "",
  ];
  if (input.template) {
    lines.push(`Template: ${input.template}`);
  }
  if (input.model) {
    lines.push(`Requested model: ${input.model}`);
  }
  if (input.reasoningLevel) {
    lines.push(`Reasoning level: ${input.reasoningLevel}`);
    lines.push(reasoningInstruction(input.reasoningLevel));
  }
  lines.push("User request:");
  lines.push(input.prompt.trim());
  if (input.context.activeFilePath) {
    lines.push("", `Active file: ${normalizeSlashes(input.context.activeFilePath)}`);
  }
  if (input.context.selection) {
    lines.push("Selection:", input.context.selection);
  }
  if (input.context.latestTerminalError) {
    lines.push("Latest terminal error:", input.context.latestTerminalError);
  }
  if (changedFiles.length > 0) {
    lines.push("Changed files already in the workspace:");
    for (const changedFile of changedFiles) {
      lines.push(`- ${normalizeSlashes(changedFile)}`);
    }
  }
  return lines.join("\n");
}

function reasoningInstruction(level: string): string {
  switch (String(level).trim().toLowerCase()) {
    case "low":
      return "Prefer a quick direct solution. Keep exploration and explanation short.";
    case "high":
      return "Spend more time planning, verifying, and reviewing before editing files.";
    default:
      return "Use a balanced amount of planning before editing files.";
  }
}

function withCursorAgentModelArg(args: string[], model: string | undefined): string[] {
  const normalizedModel = String(model ?? "").trim();
  if (!normalizedModel) {
    return [...args];
  }
  const next: string[] = [];
  for (let index = 0; index < args.length; index += 1) {
    const current = args[index];
    if (current === "--model") {
      index += 1;
      continue;
    }
    if (current.startsWith("--model=")) {
      continue;
    }
    next.push(current);
  }
  next.push("--model", normalizedModel);
  return next;
}

function parseUnifiedPatch(raw: string): UnifiedPatch {
  if (raw.trim().length === 0) {
    return { files: [] };
  }

  const patch: UnifiedPatch = { files: [] };
  let current: UnifiedPatchFile | undefined;
  let currentHunk: UnifiedPatchHunk | undefined;
  let hunkIndex = 0;

  const flushHunk = (): void => {
    if (!current || !currentHunk) {
      return;
    }
    hunkIndex += 1;
    current.hunks.push({
      ...currentHunk,
      hunkId: makeHunkId(current.path, currentHunk.header, currentHunk.lines, hunkIndex),
    });
    currentHunk = undefined;
  };

  const flushFile = (): void => {
    if (!current) {
      return;
    }
    flushHunk();
    patch.files.push(current);
    current = undefined;
    hunkIndex = 0;
  };

  for (const line of normalizeLines(raw)) {
    if (line.startsWith("diff --git ")) {
      flushFile();
      current = {
        path: parseDiffGitPath(line),
        status: "modified",
        headerLines: [line],
        hunks: [],
      };
      continue;
    }
    if (!current) {
      continue;
    }
    if (line.startsWith("@@ ")) {
      flushHunk();
      currentHunk = { hunkId: "", header: line, lines: [] };
      continue;
    }
    if (currentHunk) {
      currentHunk.lines.push(line);
      continue;
    }

    current.headerLines.push(line);
    if (line.startsWith("new file mode ")) {
      current.status = "added";
    } else if (line.startsWith("deleted file mode ")) {
      current.status = "deleted";
    } else if (line.startsWith("rename from ") || line.startsWith("rename to ")) {
      current.status = "renamed";
    } else if (line.startsWith("+++ ")) {
      const parsedPath = parsePatchPath(line.slice(4).trim());
      if (parsedPath.length > 0 && parsedPath !== "/dev/null") {
        current.path = parsedPath;
      }
    }
  }

  flushFile();
  return patch;
}

function toPatchBundle(patch: UnifiedPatch, summary: string): PatchBundle {
  const files: FilePatch[] = patch.files.map((file) => ({
    path: file.path,
    status: PATCH_STATUSES.has(file.status) ? file.status : "modified",
    hunks: file.hunks.map((hunk) => ({
      hunkId: hunk.hunkId,
      header: hunk.header,
      diff: hunk.lines.join("\n"),
      risk: "medium",
    })),
  }));
  return {
    jobId: "",
    summary:
      summary ||
      (files.length > 0
        ? `Cursor Agent proposed changes in ${files.length} file(s)`
        : "Cursor Agent completed without code changes"),
    files,
  };
}

function buildPatchForApply(
  task: CursorAgentTask,
  input: ApplyPatchInput,
): { patchText: string; selectedCount: number } {
  if (input.mode === "all") {
    return { patchText: task.rawDiff, selectedCount: countHunks(task.parsed) };
  }
  if (input.mode !== "selected") {
    throw new Error(`unsupported patch apply mode: ${input.mode}`);
  }
  if (!input.selected || input.selected.length === 0) {
    throw new Error("selected mode requires hunk selection");
  }

  const selected = new Map<string, Set<string>>();
  for (const entry of input.selected) {
    if (!selected.has(entry.path)) {
      selected.set(entry.path, new Set<string>());
    }
    for (const hunkId of entry.hunkIds) {
      selected.get(entry.path)?.add(hunkId);
    }
  }

  const filtered: UnifiedPatch = { files: [] };
  let selectedCount = 0;
  for (const file of task.parsed.files) {
    const hunksById = selected.get(file.path);
    if (!hunksById) {
      continue;
    }
    const nextFile: UnifiedPatchFile = {
      path: file.path,
      status: file.status,
      headerLines: [...file.headerLines],
      hunks: [],
    };
    for (const hunk of file.hunks) {
      if (!hunksById.has(hunk.hunkId)) {
        continue;
      }
      nextFile.hunks.push(hunk);
      selectedCount += 1;
    }
    if (nextFile.hunks.length > 0) {
      filtered.files.push(nextFile);
    }
  }
  if (selectedCount === 0) {
    throw new Error("selected hunks not found in patch");
  }
  return { patchText: renderUnifiedPatch(filtered), selectedCount };
}

function renderUnifiedPatch(patch: UnifiedPatch): string {
  const lines: string[] = [];
  patch.files.forEach((file, fileIndex) => {
    if (fileIndex > 0) {
      lines.push("");
    }
    lines.push(...file.headerLines);
    for (const hunk of file.hunks) {
      lines.push(hunk.header, ...hunk.lines);
    }
  });
  return lines.join("\n");
}

function taskSummary(cursorOutput: string, patch: UnifiedPatch): string {
  const summary = extractCursorAgentSummary(cursorOutput);
  if (summary.length > 0) {
    return summary;
  }
  if (patch.files.length === 0) {
    return "Cursor Agent completed without code changes";
  }
  return `Cursor Agent proposed changes in ${patch.files.length} file(s)`;
}

function buildProviderVisibleEvents(
  cursorOutput: string,
  patch: PatchBundle,
): ProviderVisibleEvent[] {
  const body = truncateVisibleText(extractCursorAgentVisibleText(cursorOutput), 4000);
  if (body.length === 0) {
    return [];
  }

  return [
    {
      kind: "provider_message",
      role: "assistant",
      title: "Cursor 응답",
      body,
      data: {
        source: "cursor_agent_command",
        summary: patch.summary,
        fileCount: patch.files.length,
      },
    },
  ];
}

function extractCursorAgentVisibleText(output: string): string {
  const trimmed = output.trim();
  if (trimmed.length === 0) {
    return "";
  }

  try {
    const parsed = JSON.parse(trimmed) as CursorAgentJSONOutput;
    const candidates = [
      parsed.text,
      parsed.output,
      parsed.result,
      parsed.summary,
      parsed.message,
    ];
    for (const candidate of candidates) {
      if (candidate && candidate.trim().length > 0) {
        return candidate.trim();
      }
    }
  } catch {
  }

  return trimmed;
}

function extractCursorAgentSummary(output: string): string {
  const trimmed = output.trim();
  if (trimmed.length === 0) {
    return "";
  }

  try {
    const parsed = JSON.parse(trimmed) as CursorAgentJSONOutput;
    const candidates = [
      parsed.summary,
      parsed.result,
      parsed.text,
      parsed.output,
      parsed.message,
    ];
    for (const candidate of candidates) {
      if (candidate && candidate.trim().length > 0) {
        return firstNonEmptyLine(candidate);
      }
    }
  } catch {
  }

  return firstNonEmptyLine(trimmed);
}

function parseDiffGitPath(line: string): string {
  const parts = line.trim().split(/\s+/);
  if (parts.length >= 4) {
    const preferred = parsePatchPath(parts[3]);
    if (preferred.length > 0 && preferred !== "/dev/null") {
      return preferred;
    }
    const fallback = parsePatchPath(parts[2]);
    if (fallback.length > 0 && fallback !== "/dev/null") {
      return fallback;
    }
  }
  return "";
}

function parsePatchPath(value: string): string {
  const trimmed = value.trim().replace(/^"+|"+$/g, "");
  if (trimmed.startsWith("a/") || trimmed.startsWith("b/")) {
    return normalizeSlashes(trimmed.slice(2));
  }
  return normalizeSlashes(trimmed);
}

function makeHunkId(filePath: string, header: string, lines: string[], index: number): string {
  const hash = createHash("sha1")
    .update(filePath)
    .update("\n")
    .update(header)
    .update("\n")
    .update(lines.join("\n"))
    .digest("hex");
  return `h${index}_${hash.slice(0, 8)}`;
}

function countHunks(patch: UnifiedPatch): number {
  return patch.files.reduce((total, file) => total + file.hunks.length, 0);
}

async function copyRegularFile(sourcePath: string, targetPath: string): Promise<void> {
  const sourceInfo = await stat(sourcePath);
  if (!sourceInfo.isFile()) {
    return;
  }
  await mkdir(path.dirname(targetPath), { recursive: true });
  await copyFile(sourcePath, targetPath);
}

function buildWSLCursorAgentScript(
  worktreeDir: string,
  cursorAgentBin: string,
  cursorAgentArgs: string[],
  cursorAgentEnv: string[],
): string {
  const lines: string[] = [];
  for (const [key, value] of Object.entries(envEntriesToRecord(cursorAgentEnv))) {
    lines.push(`export ${key}=${quoteForBash(value)}`);
  }
  lines.push('export PATH="$HOME/.local/bin:$PATH"');
  lines.push(`cd "$(wslpath -a ${quoteForBash(worktreeDir)})"`);

  if (cursorAgentBin.includes("/") || cursorAgentBin.includes("\\")) {
    lines.push(`agent_bin=${quoteForBash(cursorAgentBin)}`);
    lines.push('if [ ! -x "$agent_bin" ]; then echo "cursor-agent not found" >&2; exit 127; fi');
  } else {
    lines.push(
      `if command -v ${quoteForBash(cursorAgentBin)} >/dev/null 2>&1; then agent_bin=${quoteForBash(cursorAgentBin)}; ` +
        `elif [ ${quoteForBash(cursorAgentBin)} = 'cursor-agent' ] && command -v agent >/dev/null 2>&1; then agent_bin='agent'; ` +
        'else echo "cursor-agent not found" >&2; exit 127; fi',
    );
  }

  const commandLine = cursorAgentArgs.map(quoteForBash).join(" ");
  lines.push(`exec "$agent_bin"${commandLine ? ` ${commandLine}` : ""}`);
  return lines.join("; ");
}

function pickCommandOutput(result: CommandResult): string {
  const stdout = result.stdout.trim();
  if (stdout.length > 0) {
    return result.stdout;
  }
  return result.stderr;
}

function envEntriesToRecord(entries: string[]): Record<string, string> {
  const record: Record<string, string> = {};
  for (const entry of entries) {
    const separator = entry.indexOf("=");
    if (separator <= 0) {
      throw new Error(`invalid env entry: ${entry}`);
    }
    const key = entry.slice(0, separator).trim();
    if (key.length === 0) {
      throw new Error(`invalid env entry: ${entry}`);
    }
    record[key] = entry.slice(separator + 1);
  }
  return record;
}

function quoteForBash(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

function platformShellCommand(command: string): { command: string; args: string[] } {
  if (process.platform === "win32") {
    return { command: "cmd", args: ["/d", "/s", "/c", command] };
  }
  return { command: "sh", args: ["-lc", command] };
}

function normalizeLines(value: string): string[] {
  return value.replace(/\r\n/g, "\n").split("\n");
}

function normalizeSlashes(value: string): string {
  return value.replace(/\\/g, "/");
}

function sanitizeSyncPathspecs(values: string[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    const trimmed = value.trim();
    if (trimmed.length === 0 || seen.has(trimmed)) {
      continue;
    }
    seen.add(trimmed);
    result.push(trimmed);
  }
  return result.sort();
}

function joinNonEmpty(...values: string[]): string[] {
  return values
    .map((value) => value.trim())
    .filter((value) => value.length > 0);
}

function compactMessage(value: string): string {
  const first = firstNonEmptyLine(value);
  return first.length > 0 ? first : "unknown error";
}

function firstNonEmptyLine(value: string): string {
  for (const line of normalizeLines(value)) {
    const trimmed = line.trim();
    if (trimmed.length > 0) {
      return trimmed;
    }
  }
  return "";
}

function lastLines(value: string, count: number): string {
  if (count <= 0) {
    return "";
  }
  const filtered = normalizeLines(value).filter((line) => line.trim().length > 0);
  return filtered.slice(-count).join("\n");
}

function truncateVisibleText(value: string, maxLength: number): string {
  const trimmed = value.trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }
  return `${trimmed.slice(0, maxLength - 3).trimEnd()}...`;
}

function cloneProviderVisibleEvent(event: ProviderVisibleEvent): ProviderVisibleEvent {
  return {
    kind: event.kind,
    role: event.role,
    title: event.title,
    body: event.body,
    data: event.data ? { ...event.data } : undefined,
  };
}

function asErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}
