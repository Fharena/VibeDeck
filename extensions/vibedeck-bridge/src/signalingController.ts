import { spawn, type ChildProcess } from "node:child_process";
import { existsSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

type SignalingLaunchMode = "manual" | "go_run" | "binary";
type SignalingRuntimeState = "stopped" | "starting" | "running" | "error";

export interface LocalSignalingSettings {
  autoStart: boolean;
  launchMode: SignalingLaunchMode;
  host: string;
  port: number;
  goBin: string;
  repoRoot?: string;
  binaryPath?: string;
  args: string[];
  extraEnv: string[];
  pairingTtlMs: number;
  readyTimeoutMs: number;
}

export interface LocalSignalingStatus {
  state: SignalingRuntimeState;
  launchMode: SignalingLaunchMode;
  baseUrl: string;
  command: string;
  pid?: number;
  repoRoot?: string;
  lastError?: string;
  outputTail: string[];
}

export interface LocalSignalingController {
  start(settings: LocalSignalingSettings): Promise<LocalSignalingStatus>;
  stop(): Promise<void>;
  status(): LocalSignalingStatus;
  currentBaseUrl(): string;
}

export interface LocalSignalingControllerOptions {
  onStateChange?: () => void;
}

interface ActiveProcess {
  child: ChildProcess;
  settings: LocalSignalingSettings;
}

const DEFAULT_READY_TIMEOUT_MS = 8000;
const DEFAULT_PAIRING_TTL_MS = 120000;
const OUTPUT_TAIL_LIMIT = 12;
const DEFAULT_SIGNALING_BASE_URL = "http://127.0.0.1:8081";

export function createLocalSignalingController(
  options: LocalSignalingControllerOptions = {},
): LocalSignalingController {
  return new DefaultLocalSignalingController(options);
}

export function readLocalSignalingSettings(
  config: {
    get<T>(key: string, defaultValue?: T): T;
  },
  defaults: {
    agentHost?: string;
    goBin?: string;
    repoRoot?: string;
    legacyBaseUrl?: string;
  } = {},
): LocalSignalingSettings {
  const legacy = parseBaseUrl(defaults.legacyBaseUrl ?? readOptional(config, "agent.signalingBaseUrl") ?? DEFAULT_SIGNALING_BASE_URL);
  const requestedLaunchMode = normalizeLaunchMode(config.get<string>("signaling.launchMode", "auto"));
  const repoRoot = readOptional(config, "signaling.repoRoot") ?? defaults.repoRoot ?? inferRepoRoot();
  const binaryPath = readOptional(config, "signaling.binaryPath");
  const launchMode =
    requestedLaunchMode === "auto"
      ? inferLaunchMode(repoRoot, binaryPath)
      : requestedLaunchMode;
  const agentHost = readHost(defaults.agentHost);
  const configuredHost = readOptional(config, "signaling.host");
  const host =
    configuredHost ??
    (isWildcardHost(agentHost) ? agentHost : legacy.host || "127.0.0.1");

  return {
    autoStart: config.get<boolean>("signaling.autoStart", true),
    launchMode,
    host: readHost(host),
    port: normalizePort(config.get<number>("signaling.port", legacy.port), legacy.port),
    goBin: readOptional(config, "signaling.goBin") ?? defaults.goBin ?? "go",
    repoRoot,
    binaryPath,
    args: readStringArray(config, "signaling.args"),
    extraEnv: readStringArray(config, "signaling.extraEnv"),
    pairingTtlMs: normalizeDuration(
      config.get<number>("signaling.pairingTtlMs", DEFAULT_PAIRING_TTL_MS),
      DEFAULT_PAIRING_TTL_MS,
    ),
    readyTimeoutMs: normalizeDuration(
      config.get<number>("signaling.readyTimeoutMs", DEFAULT_READY_TIMEOUT_MS),
      DEFAULT_READY_TIMEOUT_MS,
    ),
  };
}

export function signalingBaseUrl(settings: LocalSignalingSettings): string {
  const host = isWildcardHost(settings.host) ? "127.0.0.1" : settings.host;
  return `http://${host}:${settings.port}`;
}

class DefaultLocalSignalingController implements LocalSignalingController {
  private readonly onStateChange?: () => void;
  private activeProcess: ActiveProcess | undefined;
  private currentStatusValue: LocalSignalingStatus = {
    state: "stopped",
    launchMode: "manual",
    baseUrl: DEFAULT_SIGNALING_BASE_URL,
    command: "manual",
    outputTail: [],
  };

  constructor(options: LocalSignalingControllerOptions) {
    this.onStateChange = options.onStateChange;
  }

  async start(settings: LocalSignalingSettings): Promise<LocalSignalingStatus> {
    if (settings.launchMode === "manual") {
      await this.stop();
      this.currentStatusValue = {
        state: "stopped",
        launchMode: settings.launchMode,
        baseUrl: signalingBaseUrl(settings),
        command: "manual",
        repoRoot: settings.repoRoot,
        outputTail: [],
      };
      this.emitChange();
      return this.status();
    }

    await this.stop();
    const baseUrl = signalingBaseUrl(settings);
    if (await isSignalingReady(baseUrl, 1200)) {
      this.currentStatusValue = {
        state: "running",
        launchMode: settings.launchMode,
        baseUrl,
        command: "existing",
        repoRoot: settings.repoRoot,
        outputTail: ["기존 signaling 인스턴스를 재사용했습니다."],
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
        baseUrl,
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
      SIGNALING_ADDR: `${settings.host}:${settings.port}`,
      PAIRING_TTL: formatDurationEnvValue(settings.pairingTtlMs),
    };

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
            ? `signaling exited unexpectedly (code=${code ?? "null"}, signal=${signal ?? "null"})`
            : this.currentStatusValue.lastError,
        outputTail: [...outputTail],
      };
      this.emitChange();
    });

    this.activeProcess = {
      child,
      settings,
    };
    this.currentStatusValue = {
      state: "starting",
      launchMode: settings.launchMode,
      baseUrl,
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

  status(): LocalSignalingStatus {
    return {
      ...this.currentStatusValue,
      outputTail: [...this.currentStatusValue.outputTail],
    };
  }

  currentBaseUrl(): string {
    return this.currentStatusValue.baseUrl || DEFAULT_SIGNALING_BASE_URL;
  }

  private emitChange(): void {
    this.onStateChange?.();
  }
}

function normalizeLaunchMode(value: string): SignalingLaunchMode | "auto" {
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

function inferLaunchMode(
  repoRoot: string | undefined,
  binaryPath: string | undefined,
): SignalingLaunchMode {
  if (binaryPath?.trim()) {
    return "binary";
  }
  return hasRepoRootLayout(repoRoot) ? "go_run" : "manual";
}

function hasRepoRootLayout(repoRoot: string | undefined): boolean {
  if (!repoRoot) {
    return false;
  }
  return (
    existsSync(path.join(repoRoot, "go.mod")) &&
    existsSync(path.join(repoRoot, "cmd", "signaling", "main.go"))
  );
}

function inferRepoRoot(): string | undefined {
  const moduleDir = path.dirname(fileURLToPath(import.meta.url));
  const candidate = path.resolve(moduleDir, "..", "..");
  return hasRepoRootLayout(candidate) ? candidate : undefined;
}

function resolveLaunch(settings: LocalSignalingSettings): {
  command: string;
  args: string[];
  cwd: string;
} {
  if (settings.launchMode === "go_run") {
    if (!settings.repoRoot || !hasRepoRootLayout(settings.repoRoot)) {
      throw new Error("signaling repo root is required for go_run mode");
    }
    return {
      command: settings.goBin,
      args: ["run", "./cmd/signaling", ...settings.args],
      cwd: settings.repoRoot,
    };
  }

  if (settings.launchMode === "binary") {
    if (!settings.binaryPath?.trim()) {
      throw new Error("signaling binary path is required for binary mode");
    }
    return {
      command: settings.binaryPath,
      args: settings.args,
      cwd: settings.repoRoot ?? path.dirname(settings.binaryPath),
    };
  }

  throw new Error("manual mode cannot be launched");
}

function parseBaseUrl(value: string): { host: string; port: number } {
  try {
    const parsed = new URL(value);
    return {
      host: parsed.hostname || "127.0.0.1",
      port: normalizePort(Number.parseInt(parsed.port || "8081", 10), 8081),
    };
  } catch {
    return {
      host: "127.0.0.1",
      port: 8081,
    };
  }
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

function readHost(value: string | undefined): string {
  const trimmed = (value ?? "").trim();
  return trimmed || "127.0.0.1";
}

function isWildcardHost(value: string | undefined): boolean {
  const normalized = (value ?? "").trim().toLowerCase();
  return normalized === "0.0.0.0" || normalized === "::";
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
  let lastError = "signaling did not become ready";
  while (Date.now() - startedAt < timeoutMs) {
    if (child.exitCode !== null) {
      throw new Error(`signaling exited before ready (code=${child.exitCode})`);
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
  throw new Error(`signaling ready timeout after ${timeoutMs}ms (${lastError})`);
}

async function isSignalingReady(baseUrl: string, timeoutMs: number): Promise<boolean> {
  try {
    const response = await httpGet(`${baseUrl}/healthz`, timeoutMs);
    return response.statusCode === 200;
  } catch {
    return false;
  }
}

async function httpGet(
  targetUrl: string,
  timeoutMs: number,
): Promise<{ statusCode: number; body: string }> {
  return await new Promise((resolve, reject) => {
    const request = http.request(targetUrl, { method: "GET" }, (response) => {
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

    request.end();
    request.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
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
