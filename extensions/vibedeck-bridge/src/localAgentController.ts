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
      this.currentStatusValue = {
        state: "running",
        launchMode: settings.launchMode,
        baseUrl,
        command: `existing ${baseUrl}`,
        repoRoot: settings.repoRoot,
        outputTail: ["existing agent reused"],
      };
      this.emitChange();
      return this.status();
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
        this.activeProcess = undefined;
        this.currentStatusValue = {
          ...this.currentStatusValue,
          state: "running",
          pid: undefined,
          command: `existing ${baseUrl}`,
          outputTail: [...outputTail, "existing agent reused after bind conflict"],
        };
        this.emitChange();
        return this.status();
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

async function httpGet(
  targetUrl: string,
  timeoutMs: number,
): Promise<{ statusCode: number; body: string }> {
  return await new Promise((resolve, reject) => {
    const client = targetUrl.startsWith("https:") ? https : http;
    const request = client.get(targetUrl, (response) => {
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
    });

    const timer = setTimeout(() => {
      request.destroy(new Error("request timeout"));
    }, timeoutMs);

    request.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

function inferRepoRoot(): string | undefined {
  const moduleDir = path.dirname(fileURLToPath(import.meta.url));
  const candidate = path.resolve(moduleDir, "..", "..");
  return hasRepoRootLayout(candidate) ? candidate : undefined;
}
