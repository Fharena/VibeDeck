import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import http from "node:http";
import https from "node:https";
import path from "node:path";
import { fileURLToPath } from "node:url";

type AgentLaunchMode = "manual" | "go_run" | "binary";
type AgentRuntimeState = "stopped" | "starting" | "running" | "error";

export interface LocalAgentSettings {
  autoStart: boolean;
  launchMode: AgentLaunchMode;
  host: string;
  port: number;
  goBin: string;
  repoRoot?: string;
  binaryPath?: string;
  args: string[];
  extraEnv: string[];
  runProfileFile?: string;
  signalingBaseUrl: string;
  readyTimeoutMs: number;
  controlTimeoutDefaultMs: number;
  controlTimeoutPromptSubmitMs: number;
  controlTimeoutPatchApplyMs: number;
  controlTimeoutRunProfileMs: number;
}

export interface LocalAgentStatus {
  state: AgentRuntimeState;
  launchMode: AgentLaunchMode;
  baseUrl: string;
  command: string;
  pid?: number;
  repoRoot?: string;
  lastError?: string;
  outputTail: string[];
}

interface ActiveProcess {
  child: ChildProcess;
  settings: LocalAgentSettings;
  bridgeAddress: string;
}

interface AgentRuntimeInfo {
  name?: string;
  ready?: boolean;
}

export interface LocalAgentController {
  start(settings: LocalAgentSettings, bridgeAddress: string): Promise<LocalAgentStatus>;
  stop(): Promise<void>;
  status(): LocalAgentStatus;
  currentBaseUrl(): string;
}

export interface LocalAgentControllerOptions {
  onStateChange?: () => void;
}

const DEFAULT_READY_TIMEOUT_MS = 15000;
const DEFAULT_CONTROL_TIMEOUT_DEFAULT_MS = 5000;
const DEFAULT_CONTROL_TIMEOUT_PROMPT_SUBMIT_MS = 300000;
const DEFAULT_CONTROL_TIMEOUT_PATCH_APPLY_MS = 30000;
const DEFAULT_CONTROL_TIMEOUT_RUN_PROFILE_MS = 300000;
const OUTPUT_TAIL_LIMIT = 12;
const DEFAULT_AGENT_BASE_URL = "http://127.0.0.1:8080";

export function createLocalAgentController(
  options: LocalAgentControllerOptions = {},
): LocalAgentController {
  return new DefaultLocalAgentController(options);
}

export function readLocalAgentSettings(
  config: {
    get<T>(key: string, defaultValue?: T): T;
  },
): LocalAgentSettings {
  const inferredRepoRoot = inferRepoRoot();
  const repoRoot = readOptional(config, "agent.repoRoot") ?? inferredRepoRoot;
  const requestedLaunchMode = normalizeLaunchMode(config.get<string>("agent.launchMode", "auto"));
  const launchMode =
    requestedLaunchMode === "auto"
      ? inferLaunchMode(repoRoot)
      : requestedLaunchMode;
  const host = readHost(config.get<string>("agent.host", "127.0.0.1"));
  const port = normalizePort(config.get<number>("agent.port", 8080), 8080);
  const binaryPath = readOptional(config, "agent.binaryPath");
  const runProfileFile =
    readOptional(config, "agent.runProfileFile") ??
    (repoRoot ? path.join(repoRoot, "configs", "run-profiles.json") : undefined);

  return {
    autoStart: config.get<boolean>("agent.autoStart", true),
    launchMode,
    host,
    port,
    goBin: readOptional(config, "agent.goBin") ?? "go",
    repoRoot,
    binaryPath,
    args: readStringArray(config, "agent.args"),
    extraEnv: readStringArray(config, "agent.extraEnv"),
    runProfileFile,
    signalingBaseUrl:
      readOptional(config, "agent.signalingBaseUrl") ?? "http://127.0.0.1:8081",
    readyTimeoutMs: normalizeDuration(
      config.get<number>("agent.readyTimeoutMs", DEFAULT_READY_TIMEOUT_MS),
      DEFAULT_READY_TIMEOUT_MS,
    ),
    controlTimeoutDefaultMs: normalizeDuration(
      config.get<number>("agent.controlTimeoutDefaultMs", DEFAULT_CONTROL_TIMEOUT_DEFAULT_MS),
      DEFAULT_CONTROL_TIMEOUT_DEFAULT_MS,
    ),
    controlTimeoutPromptSubmitMs: normalizeDuration(
      config.get<number>(
        "agent.controlTimeoutPromptSubmitMs",
        DEFAULT_CONTROL_TIMEOUT_PROMPT_SUBMIT_MS,
      ),
      DEFAULT_CONTROL_TIMEOUT_PROMPT_SUBMIT_MS,
    ),
    controlTimeoutPatchApplyMs: normalizeDuration(
      config.get<number>(
        "agent.controlTimeoutPatchApplyMs",
        DEFAULT_CONTROL_TIMEOUT_PATCH_APPLY_MS,
      ),
      DEFAULT_CONTROL_TIMEOUT_PATCH_APPLY_MS,
    ),
    controlTimeoutRunProfileMs: normalizeDuration(
      config.get<number>(
        "agent.controlTimeoutRunProfileMs",
        DEFAULT_CONTROL_TIMEOUT_RUN_PROFILE_MS,
      ),
      DEFAULT_CONTROL_TIMEOUT_RUN_PROFILE_MS,
    ),
  };
}

class DefaultLocalAgentController implements LocalAgentController {
  private readonly onStateChange?: () => void;
  private activeProcess: ActiveProcess | undefined;
  private currentStatusValue: LocalAgentStatus = {
    state: "stopped",
    launchMode: "manual",
    baseUrl: DEFAULT_AGENT_BASE_URL,
    command: "manual",
    outputTail: [],
  };

  constructor(options: LocalAgentControllerOptions) {
    this.onStateChange = options.onStateChange;
  }

  async start(settings: LocalAgentSettings, bridgeAddress: string): Promise<LocalAgentStatus> {
    if (settings.launchMode === "manual") {
      await this.stop();
      this.currentStatusValue = {
        state: "stopped",
        launchMode: settings.launchMode,
        baseUrl: agentBaseUrl(settings),
        command: "manual",
        repoRoot: settings.repoRoot,
        outputTail: [],
      };
      this.emitChange();
      return this.status();
    }

    await this.stop();
    const baseUrl = agentBaseUrl(settings);
    if (await isAgentReady(baseUrl, 1200)) {
      const stopped = await stopExistingManagedAgent(baseUrl, settings.port, settings.readyTimeoutMs);
      if (await isAgentReady(baseUrl, 1200)) {
        this.currentStatusValue = {
          state: "error",
          launchMode: settings.launchMode,
          baseUrl,
          command: settings.launchMode,
          repoRoot: settings.repoRoot,
          lastError: stopped
            ? "기존 agent 재시작 대기 중에 포트가 계속 점유되어 있습니다."
            : "기존 VibeDeck agent를 정리하지 못했습니다. agent 포트(8080)를 쓰는 프로세스를 확인해주세요.",
          outputTail: stopped
            ? ["기존 agent 종료 후에도 포트가 유지되었습니다."]
            : ["기존 agent 종료 실패"],
        };
        this.emitChange();
        return this.status();
      }
    }

    let resolvedLaunch: { command: string; args: string[]; cwd: string };
    try {
      resolvedLaunch = resolveLaunch(settings);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.currentStatusValue = {
        state: "error",
        launchMode: settings.launchMode,
        baseUrl: agentBaseUrl(settings),
        command: settings.launchMode,
        repoRoot: settings.repoRoot,
        lastError: message,
        outputTail: [],
      };
      this.emitChange();
      return this.status();
    }
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      ...parseEnvPairs(settings.extraEnv),
      AGENT_ADDR: listenAddress(settings),
      CURSOR_BRIDGE_TCP_ADDR: bridgeAddress,
      SIGNALING_BASE_URL: settings.signalingBaseUrl,
      CONTROL_TIMEOUT_DEFAULT: formatDurationEnvValue(settings.controlTimeoutDefaultMs),
      CONTROL_TIMEOUT_PROMPT_SUBMIT: formatDurationEnvValue(
        settings.controlTimeoutPromptSubmitMs,
      ),
      CONTROL_TIMEOUT_PATCH_APPLY: formatDurationEnvValue(settings.controlTimeoutPatchApplyMs),
      CONTROL_TIMEOUT_RUN_PROFILE: formatDurationEnvValue(settings.controlTimeoutRunProfileMs),
    };
    if (settings.runProfileFile) {
      env.RUN_PROFILE_FILE = settings.runProfileFile;
    }

    const child = spawn(resolvedLaunch.command, resolvedLaunch.args, {
      cwd: resolvedLaunch.cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });

    const outputTail: string[] = [];
    const pushOutput = (chunk: Buffer | string) => {
      for (const line of String(chunk)
        .split(/\r?\n/)
        .map((item) => item.trim())
        .filter(Boolean)) {
        outputTail.push(line);
      }
      if (outputTail.length > OUTPUT_TAIL_LIMIT) {
        outputTail.splice(0, outputTail.length - OUTPUT_TAIL_LIMIT);
      }
      this.currentStatusValue = {
        ...this.currentStatusValue,
        outputTail: [...outputTail],
      };
      this.emitChange();
    };

    child.stdout?.on("data", pushOutput);
    child.stderr?.on("data", pushOutput);
    child.once("error", (error) => {
      this.currentStatusValue = {
        ...this.currentStatusValue,
        state: "error",
        lastError: error.message,
      };
      this.emitChange();
    });
    child.once("exit", (code, signal) => {
      if (this.activeProcess?.child !== child) {
        return;
      }
      this.activeProcess = undefined;
      this.currentStatusValue = {
        ...this.currentStatusValue,
        state: this.currentStatusValue.state === "running" ? "error" : this.currentStatusValue.state,
        pid: undefined,
        lastError:
          this.currentStatusValue.state === "running"
            ? `agent exited unexpectedly (code=${code ?? "null"}, signal=${signal ?? "null"})`
            : this.currentStatusValue.lastError,
        outputTail: [...outputTail],
      };
      this.emitChange();
    });

    this.activeProcess = {
      child,
      settings,
      bridgeAddress,
    };
    this.currentStatusValue = {
      state: "starting",
      launchMode: settings.launchMode,
      baseUrl: agentBaseUrl(settings),
      command: renderCommand(resolvedLaunch.command, resolvedLaunch.args),
      pid: child.pid,
      repoRoot: settings.repoRoot,
      outputTail: [],
    };
      this.emitChange();

    try {
      await waitForReady(baseUrl, settings.readyTimeoutMs, child);
      this.currentStatusValue = {
        ...this.currentStatusValue,
        state: "running",
        outputTail: [...outputTail],
      };
      this.emitChange();
      return this.status();
    } catch (error) {
      if (await isAgentReady(baseUrl, 1200)) {
        await stopExistingManagedAgent(baseUrl, settings.port, 2500);
      }
      const message = error instanceof Error ? error.message : String(error);
      this.currentStatusValue = {
        ...this.currentStatusValue,
        state: "error",
        lastError: message,
        outputTail: [...outputTail],
      };
      this.emitChange();
      await this.stop();
      this.currentStatusValue = {
        ...this.currentStatusValue,
        state: "error",
        lastError: message,
        outputTail: [...outputTail],
      };
      this.emitChange();
      return this.status();
    }
  }

  async stop(): Promise<void> {
    const active = this.activeProcess;
    this.activeProcess = undefined;
    if (active?.child && active.child.exitCode === null) {
      active.child.kill();
      await waitForExit(active.child, 3000);
    }

    this.currentStatusValue = {
      ...this.currentStatusValue,
      state: "stopped",
      pid: undefined,
    };
    this.emitChange();
  }

  status(): LocalAgentStatus {
    return {
      ...this.currentStatusValue,
      outputTail: [...this.currentStatusValue.outputTail],
    };
  }

  currentBaseUrl(): string {
    return this.currentStatusValue.baseUrl || DEFAULT_AGENT_BASE_URL;
  }

  private emitChange(): void {
    this.onStateChange?.();
  }
}

function normalizeLaunchMode(value: string): AgentLaunchMode | "auto" {
  switch ((value ?? "").trim()) {
    case "go_run":
      return "go_run";
    case "binary":
      return "binary";
    case "manual":
      return "manual";
    default:
      return "auto";
  }
}

function inferLaunchMode(repoRoot: string | undefined): AgentLaunchMode {
  return hasRepoRootLayout(repoRoot) ? "go_run" : "manual";
}

function hasRepoRootLayout(repoRoot: string | undefined): boolean {
  if (!repoRoot) {
    return false;
  }
  return (
    existsSync(path.join(repoRoot, "go.mod")) &&
    existsSync(path.join(repoRoot, "cmd", "agent", "main.go"))
  );
}

function readOptional(
  config: {
    get<T>(key: string, defaultValue?: T): T;
  },
  key: string,
): string | undefined {
  const value = config.get<string | undefined>(key)?.trim();
  return value ? value : undefined;
}

function readStringArray(
  config: {
    get<T>(key: string, defaultValue?: T): T;
  },
  key: string,
): string[] {
  const value = config.get<unknown[]>(key, []);
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((item): item is string => typeof item === "string" && item.trim().length > 0);
}

function normalizePort(value: number, fallback: number): number {
  if (!Number.isFinite(value) || value < 1 || value > 65535) {
    return fallback;
  }
  return Math.trunc(value);
}

function normalizeDuration(value: number, fallback: number): number {
  if (!Number.isFinite(value) || value < 1000) {
    return fallback;
  }
  return Math.trunc(value);
}

function formatDurationEnvValue(valueMs: number): string {
  return `${Math.trunc(valueMs)}ms`;
}

function readHost(value: string | undefined): string {
  const trimmed = (value ?? "").trim();
  return trimmed || "127.0.0.1";
}

function listenAddress(settings: LocalAgentSettings): string {
  return `${settings.host}:${settings.port}`;
}

function agentBaseUrl(settings: LocalAgentSettings): string {
  const host =
    settings.host === "0.0.0.0" || settings.host === "::" ? "127.0.0.1" : settings.host;
  return `http://${host}:${settings.port}`;
}

function resolveLaunch(settings: LocalAgentSettings): {
  command: string;
  args: string[];
  cwd: string;
} {
  if (settings.launchMode === "go_run") {
    if (!settings.repoRoot || !hasRepoRootLayout(settings.repoRoot)) {
      throw new Error("agent repo root is required for go_run mode");
    }
    return {
      command: settings.goBin,
      args: ["run", "./cmd/agent", ...settings.args],
      cwd: settings.repoRoot,
    };
  }

  if (settings.launchMode === "binary") {
    if (!settings.binaryPath?.trim()) {
      throw new Error("agent binary path is required for binary mode");
    }
    return {
      command: settings.binaryPath,
      args: settings.args,
      cwd: settings.repoRoot ?? path.dirname(settings.binaryPath),
    };
  }

  throw new Error("manual mode cannot be launched");
}

function parseEnvPairs(items: string[]): Record<string, string> {
  const env: Record<string, string> = {};
  for (const item of items) {
    const separator = item.indexOf("=");
    if (separator <= 0) {
      continue;
    }
    const key = item.slice(0, separator).trim();
    if (!key) {
      continue;
    }
    env[key] = item.slice(separator + 1);
  }
  return env;
}

function renderCommand(command: string, args: string[]): string {
  return [command, ...args.map(quoteArgument)].join(" ");
}

function quoteArgument(value: string): string {
  if (!value.includes(" ") && !value.includes('"')) {
    return value;
  }
  return `"${value.replaceAll('"', '\\"')}"`;
}

async function waitForReady(baseUrl: string, timeoutMs: number, child: ChildProcess): Promise<void> {
  const startedAt = Date.now();
  let lastError = "agent did not become ready";
  while (Date.now() - startedAt < timeoutMs) {
    if (child.exitCode !== null) {
      throw new Error(`agent exited before ready (code=${child.exitCode})`);
    }

    try {
      const response = await httpGet(`${baseUrl}/healthz`, 1200);
      if (response.statusCode === 200) {
        return;
      }
      lastError = `healthz returned ${response.statusCode}`;
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
    await delay(250);
  }
  throw new Error(`agent ready timeout after ${timeoutMs}ms (${lastError})`);
}

async function isAgentReady(baseUrl: string, timeoutMs: number): Promise<boolean> {
  try {
    const response = await httpGet(`${baseUrl}/healthz`, timeoutMs);
    return response.statusCode === 200;
  } catch {
    return false;
  }
}

async function waitForExit(child: ChildProcess, timeoutMs: number): Promise<void> {
  if (child.exitCode !== null) {
    return;
  }

  await new Promise<void>((resolve) => {
    const timer = setTimeout(() => {
      if (child.exitCode === null) {
        child.kill("SIGKILL");
      }
      resolve();
    }, timeoutMs);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function stopExistingManagedAgent(
  baseUrl: string,
  port: number,
  timeoutMs: number,
): Promise<boolean> {
  const runtimeInfo = await readAgentRuntimeInfo(baseUrl, 1200);
  if (!looksLikeManagedAgent(runtimeInfo)) {
    return false;
  }

  await requestAgentShutdown(baseUrl, timeoutMs);
  if (await waitUntilAgentStops(baseUrl, timeoutMs)) {
    return true;
  }

  const killed = await killProcessListeningOnPort(port);
  if (!killed) {
    return false;
  }
  return await waitUntilAgentStops(baseUrl, timeoutMs);
}

async function waitUntilAgentStops(baseUrl: string, timeoutMs: number): Promise<boolean> {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (!(await isAgentReady(baseUrl, 800))) {
      return true;
    }
    await delay(200);
  }
  return !(await isAgentReady(baseUrl, 800));
}

async function readAgentRuntimeInfo(
  baseUrl: string,
  timeoutMs: number,
): Promise<AgentRuntimeInfo | undefined> {
  try {
    const response = await httpRequest(`${baseUrl}/v1/agent/runtime/adapter`, "GET", timeoutMs);
    if (response.statusCode !== 200) {
      return undefined;
    }
    const value = JSON.parse(response.body) as Record<string, unknown>;
    return {
      name: typeof value.name === "string" ? value.name : undefined,
      ready: value.ready === true,
    };
  } catch {
    return undefined;
  }
}

function looksLikeManagedAgent(info: AgentRuntimeInfo | undefined): boolean {
  return info?.ready === true && typeof info.name === "string" && info.name.length > 0;
}

async function requestAgentShutdown(baseUrl: string, timeoutMs: number): Promise<boolean> {
  try {
    const response = await httpRequest(
      `${baseUrl}/v1/agent/runtime/shutdown`,
      "POST",
      timeoutMs,
      JSON.stringify({ reason: "extension restart" }),
      "application/json",
    );
    return response.statusCode === 200;
  } catch {
    return false;
  }
}

async function killProcessListeningOnPort(port: number): Promise<boolean> {
  const pids = await findListeningPids(port);
  if (pids.length === 0) {
    return false;
  }

  let killed = false;
  for (const pid of pids) {
    if (!(await killProcessByPid(pid))) {
      continue;
    }
    killed = true;
  }
  return killed;
}

async function findListeningPids(port: number): Promise<number[]> {
  try {
    if (process.platform === "win32") {
      const result = await runCommandCapture("powershell.exe", [
        "-NoProfile",
        "-Command",
        `$items = Get-NetTCPConnection -State Listen -LocalPort ${port} -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique; foreach ($item in $items) { Write-Output $item }`,
      ]);
      return result.stdout
        .split(/\r?\n/)
        .map((line) => Number.parseInt(line.trim(), 10))
        .filter((value) => Number.isFinite(value) && value > 0);
    }

    const result = await runCommandCapture("sh", [
      "-lc",
      `lsof -ti tcp:${port} -sTCP:LISTEN 2>/dev/null || true`,
    ]);
    return result.stdout
      .split(/\r?\n/)
      .map((line) => Number.parseInt(line.trim(), 10))
      .filter((value) => Number.isFinite(value) && value > 0);
  } catch {
    return [];
  }
}

async function killProcessByPid(pid: number): Promise<boolean> {
  try {
    if (process.platform === "win32") {
      const result = await runCommandCapture("taskkill", ["/PID", String(pid), "/T", "/F"]);
      return result.exitCode === 0;
    }

    const result = await runCommandCapture("kill", ["-TERM", String(pid)]);
    return result.exitCode === 0;
  } catch {
    return false;
  }
}

async function httpGet(
  targetUrl: string,
  timeoutMs: number,
): Promise<{ statusCode: number; body: string }> {
  return await httpRequest(targetUrl, "GET", timeoutMs);
}

async function httpRequest(
  targetUrl: string,
  method: "GET" | "POST",
  timeoutMs: number,
  body?: string,
  contentType?: string,
): Promise<{ statusCode: number; body: string }> {
  return await new Promise((resolve, reject) => {
    const requestFactory = targetUrl.startsWith("https:") ? https.request : http.request;
    const request = requestFactory(
      targetUrl,
      {
        method,
        headers:
          body && contentType
            ? {
                "Content-Type": contentType,
                "Content-Length": Buffer.byteLength(body),
              }
            : undefined,
      },
      (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => {
        body += chunk;
      });
      response.on("end", () => {
        clearTimeout(timer);
        resolve({
          statusCode: response.statusCode ?? 0,
          body,
        });
      });
      },
    );

    const timer = setTimeout(() => {
      request.destroy(new Error("request timeout"));
    }, timeoutMs);

    if (body) {
      request.write(body);
    }
    request.end();

    request.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function runCommandCapture(
  command: string,
  args: string[],
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk) => {
      stdout += String(chunk);
    });
    child.stderr?.on("data", (chunk) => {
      stderr += String(chunk);
    });
    child.once("error", (error) => reject(error));
    child.once("close", (code) => {
      resolve({
        stdout,
        stderr,
        exitCode: code ?? -1,
      });
    });
  });
}

function inferRepoRoot(): string | undefined {
  const moduleDir = path.dirname(fileURLToPath(import.meta.url));
  const candidate = path.resolve(moduleDir, "..", "..");
  return hasRepoRootLayout(candidate) ? candidate : undefined;
}
