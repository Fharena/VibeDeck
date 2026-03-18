import os from "node:os";
import { randomBytes } from "node:crypto";

import QRCode from "qrcode";

import {
  createAgentPanelApi,
  type AgentPanelApi,
  type AgentPanelBootstrap,
} from "./agentPanelApi.js";
import type {
  ThreadPanelWebviewPanelLike,
} from "./threadPanelController.js";

export interface MobileBootstrapConfigurationLike {
  get<T>(key: string, defaultValue?: T): T;
}

export interface MobileBootstrapWorkspaceLike {
  getConfiguration(section?: string): MobileBootstrapConfigurationLike;
}

export interface MobileBootstrapWindowLike {
  createWebviewPanel(
    viewType: string,
    title: string,
    column: number,
    options: { enableScripts: boolean; retainContextWhenHidden?: boolean },
  ): ThreadPanelWebviewPanelLike;
  showInformationMessage(message: string): unknown;
  showWarningMessage(message: string): unknown;
  showErrorMessage(message: string): unknown;
}

export interface MobileBootstrapEnvLike {
  clipboard: {
    writeText(text: string): Promise<void>;
  };
}

export interface MobileBootstrapVscodeLike {
  workspace: MobileBootstrapWorkspaceLike;
  window: MobileBootstrapWindowLike;
  env: MobileBootstrapEnvLike;
  viewColumn: {
    one: number;
  };
}

export interface MobileBootstrapController {
  openOrReveal(): Promise<void>;
  copyLink(): Promise<void>;
  dispose(): void;
}

export interface MobileBootstrapControllerDependencies {
  api?: AgentPanelApi;
  resolveLanHost?: (configuredHost: string) => string | undefined;
  renderQRCodeSvg?: (value: string) => Promise<string>;
  ensureAgentReady?: () => Promise<void>;
}

interface MobileBootstrapSettings {
  agentBaseUrl: string;
  agentHost: string;
  agentPort: number;
  signalingBaseUrl: string;
  hostOverride: string;
  scheme: string;
}

interface MobileBootstrapViewState {
  bootstrapLink: string;
  qrSvg: string;
  publicAgentBaseUrl: string;
  publicSignalingBaseUrl: string;
  workspaceRoot: string;
  currentThreadId: string;
  currentSessionId: string;
  provider: string;
  hostSource: string;
  warning: string;
}

interface MobileBootstrapMessage {
  type?: unknown;
}

export function createMobileBootstrapController(
  vscodeLike: MobileBootstrapVscodeLike,
  dependencies: MobileBootstrapControllerDependencies = {},
): MobileBootstrapController {
  return new DefaultMobileBootstrapController(vscodeLike, dependencies);
}

export function buildMobileBootstrapLink(input: {
  scheme: string;
  agentBaseUrl: string;
  signalingBaseUrl: string;
  threadId: string;
  sessionId?: string;
}): string {
  const scheme = input.scheme.trim() || "vibedeck";
  const url = new URL(`${scheme}://bootstrap`);
  if (input.agentBaseUrl.trim()) {
    url.searchParams.set("agent", input.agentBaseUrl.trim());
  }
  if (input.signalingBaseUrl.trim()) {
    url.searchParams.set("signaling", input.signalingBaseUrl.trim());
  }
  if (input.threadId.trim()) {
    url.searchParams.set("thread", input.threadId.trim());
  }
  if ((input.sessionId ?? "").trim()) {
    url.searchParams.set("session", (input.sessionId ?? "").trim());
  }
  return url.toString();
}

export function rewriteBootstrapBaseUrl(baseUrl: string, hostOverride: string): string {
  const trimmedBaseUrl = baseUrl.trim();
  const trimmedHostOverride = hostOverride.trim();
  if (!trimmedBaseUrl || !trimmedHostOverride) {
    return trimmedBaseUrl;
  }

  const url = new URL(trimmedBaseUrl);
  url.hostname = trimmedHostOverride;
  const pathname = url.pathname === "/" ? "" : url.pathname;
  return `${url.protocol}//${url.host}${pathname}${url.search}${url.hash}`;
}

export function pickMobileBootstrapHost(configuredHost: string): string | undefined {
  const trimmedConfiguredHost = configuredHost.trim();
  if (trimmedConfiguredHost && !isWildcardHost(trimmedConfiguredHost) && !isLoopbackHost(trimmedConfiguredHost)) {
    return trimmedConfiguredHost;
  }

  const candidates: string[] = [];
  const interfaces = os.networkInterfaces();
  for (const addresses of Object.values(interfaces)) {
    for (const address of addresses ?? []) {
      if (!address || address.internal || address.family !== "IPv4") {
        continue;
      }
      const value = address.address.trim();
      if (!value || value.startsWith("169.254.")) {
        continue;
      }
      candidates.push(value);
    }
  }

  candidates.sort((left, right) => rankHost(left) - rankHost(right) || left.localeCompare(right));
  return candidates[0];
}

class DefaultMobileBootstrapController implements MobileBootstrapController {
  private readonly vscode: MobileBootstrapVscodeLike;
  private readonly api: AgentPanelApi;
  private readonly resolveLanHost: (configuredHost: string) => string | undefined;
  private readonly renderQRCodeSvg: (value: string) => Promise<string>;
  private readonly ensureAgentReady: () => Promise<void>;
  private panel: ThreadPanelWebviewPanelLike | undefined;

  constructor(
    vscodeLike: MobileBootstrapVscodeLike,
    dependencies: MobileBootstrapControllerDependencies,
  ) {
    this.vscode = vscodeLike;
    this.api = dependencies.api ?? createAgentPanelApi();
    this.resolveLanHost = dependencies.resolveLanHost ?? pickMobileBootstrapHost;
    this.renderQRCodeSvg =
      dependencies.renderQRCodeSvg ??
      ((value) =>
        QRCode.toString(value, {
          type: "svg",
          margin: 1,
          width: 240,
          color: {
            dark: "#0f1720",
            light: "#ffffff",
          },
        }));
    this.ensureAgentReady = dependencies.ensureAgentReady ?? (async () => undefined);
  }

  async openOrReveal(): Promise<void> {
    if (this.panel) {
      this.panel.reveal(this.vscode.viewColumn.one);
      await this.refresh();
      return;
    }

    const panel = this.vscode.window.createWebviewPanel(
      "vibedeckMobileBootstrap",
      "VibeDeck Mobile Bootstrap",
      this.vscode.viewColumn.one,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
      },
    );

    const nonce = randomBytes(16).toString("hex");
    panel.webview.html = renderMobileBootstrapHtml(nonce);
    panel.onDidDispose(() => {
      this.panel = undefined;
    });
    panel.webview.onDidReceiveMessage((message) => {
      void this.handleMessage(message);
    });

    this.panel = panel;
    await this.refresh();
  }

  async copyLink(): Promise<void> {
    try {
      const state = await this.buildState();
      await this.vscode.env.clipboard.writeText(state.bootstrapLink);
      void this.vscode.window.showInformationMessage(
        `Copied mobile bootstrap link: ${state.bootstrapLink}`,
      );
    } catch (error) {
      const message = describeBootstrapError(error);
      void this.vscode.window.showErrorMessage(`VibeDeck mobile bootstrap failed: ${message}`);
    }
  }

  dispose(): void {
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  private async handleMessage(message: unknown): Promise<void> {
    const typed = (message ?? {}) as MobileBootstrapMessage;
    const type = typeof typed.type === "string" ? typed.type : "";
    if (type === "copy-link") {
      await this.copyLink();
      return;
    }
    if (type === "refresh") {
      await this.refresh();
    }
  }

  private async refresh(): Promise<void> {
    const panel = this.panel;
    if (!panel) {
      return;
    }

    try {
      const state = await this.buildState();
      await panel.webview.postMessage({ type: "state", state });
    } catch (error) {
      const message = describeBootstrapError(error);
      await panel.webview.postMessage({
        type: "state",
        state: {
          bootstrapLink: "",
          qrSvg: "",
          publicAgentBaseUrl: "",
          publicSignalingBaseUrl: "",
          workspaceRoot: "",
          currentThreadId: "",
          currentSessionId: "",
          provider: "",
          hostSource: "",
          warning: message,
        } satisfies MobileBootstrapViewState,
      });
      void this.vscode.window.showErrorMessage(`VibeDeck mobile bootstrap failed: ${message}`);
    }
  }

  private async buildState(): Promise<MobileBootstrapViewState> {
    await this.ensureAgentReady();
    const settings = this.readSettings();
    const bootstrap = await this.api.bootstrap(settings.agentBaseUrl);

    const effectiveHost =
      settings.hostOverride ||
      this.resolveLanHost(new URL(settings.agentBaseUrl).hostname) ||
      new URL(settings.agentBaseUrl).hostname;

    const publicAgentBaseUrl = rewriteBootstrapBaseUrl(
      bootstrap.agentBaseUrl || settings.agentBaseUrl,
      effectiveHost,
    );
    const publicSignalingBaseUrl = rewriteBootstrapBaseUrl(
      bootstrap.signalingBaseUrl || settings.signalingBaseUrl,
      effectiveHost,
    );
    const currentSessionId = bootstrap.currentSessionId || "";
    const currentThreadId = bootstrap.currentThreadId || bootstrap.currentSessionId;
    const bootstrapLink = buildMobileBootstrapLink({
      scheme: settings.scheme,
      agentBaseUrl: publicAgentBaseUrl,
      signalingBaseUrl: publicSignalingBaseUrl,
      threadId: currentThreadId,
      sessionId: currentSessionId,
    });

    const warning = buildWarning(settings, effectiveHost, publicAgentBaseUrl);
    return {
      bootstrapLink,
      qrSvg: await this.renderQRCodeSvg(bootstrapLink),
      publicAgentBaseUrl,
      publicSignalingBaseUrl,
      workspaceRoot: bootstrap.workspaceRoot,
      currentThreadId,
      currentSessionId,
      provider: bootstrap.adapter.provider,
      hostSource: settings.hostOverride ? "manual" : effectiveHost,
      warning,
    };
  }

  private readSettings(): MobileBootstrapSettings {
    const config = this.vscode.workspace.getConfiguration("vibedeckBridge");
    const configuredAgentBaseUrl = text(config.get<string>("agentBaseUrl", "")).trim();
    const agentHost = text(config.get<string>("agent.host", "127.0.0.1")).trim() || "127.0.0.1";
    const agentPort = normalizePort(config.get<number>("agent.port", 8080), 8080);
    const signalingBaseUrl =
      text(config.get<string>("agent.signalingBaseUrl", "http://127.0.0.1:8081")).trim() ||
      "http://127.0.0.1:8081";
    const scheme = text(config.get<string>("mobileBootstrap.scheme", "vibedeck")).trim() || "vibedeck";
    return {
      agentBaseUrl: configuredAgentBaseUrl || normalizeAgentBaseUrl(agentHost, agentPort),
      agentHost,
      agentPort,
      signalingBaseUrl,
      hostOverride: text(config.get<string>("mobileBootstrap.hostOverride", "")).trim(),
      scheme,
    };
  }
}

function normalizeAgentBaseUrl(host: string, port: number): string {
  const normalizedHost = host === "0.0.0.0" || host === "::" ? "127.0.0.1" : host;
  return `http://${normalizedHost}:${port}`;
}

function normalizePort(value: number, fallback: number): number {
  if (!Number.isFinite(value) || value < 1 || value > 65535) {
    return fallback;
  }
  return Math.trunc(value);
}

function text(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }
  if (value == null) {
    return "";
  }
  return String(value);
}

function isLoopbackHost(host: string): boolean {
  const normalized = host.trim().toLowerCase();
  return normalized === "127.0.0.1" || normalized === "localhost" || normalized === "::1";
}

function isWildcardHost(host: string): boolean {
  const normalized = host.trim().toLowerCase();
  return normalized === "0.0.0.0" || normalized === "::";
}

function rankHost(host: string): number {
  if (host.startsWith("192.168.")) {
    return 0;
  }
  if (host.startsWith("10.")) {
    return 1;
  }
  if (host.startsWith("172.")) {
    return 2;
  }
  return 3;
}

function buildWarning(
  settings: MobileBootstrapSettings,
  host: string,
  publicAgentBaseUrl: string,
): string {
  if (isLoopbackHost(settings.agentHost)) {
    return `현재 local agent가 ${settings.agentHost}:${settings.agentPort} loopback에만 바인딩돼 있어 휴대폰이 직접 붙지 못합니다. Cursor 설정에서 vibedeckBridge.agent.host를 0.0.0.0으로 바꾸고 VibeDeck: Restart Local Agent를 실행하세요. signaling 서버도 별도로 실행해야 합니다.`;
  }
  if (isLoopbackHost(host)) {
    return "LAN 주소를 찾지 못해 localhost 기반 링크를 만들었습니다. 휴대폰에서는 직접 연결되지 않을 수 있습니다.";
  }
  if (publicAgentBaseUrl.includes("127.0.0.1") || publicAgentBaseUrl.includes("localhost")) {
    return "bootstrap 링크에 localhost가 남아 있습니다. vibedeckBridge.mobileBootstrap.hostOverride 설정을 확인하세요.";
  }
  return "";
}

function describeBootstrapError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes("ECONNREFUSED") || message.includes("connect ECONNREFUSED")) {
    return "로컬 agent에 연결하지 못했습니다. 먼저 VibeDeck: Restart Local Agent를 실행해 보세요. 실기기 연결이라면 vibedeckBridge.agent.host를 0.0.0.0으로 바꾸고 다시 시도해야 합니다.";
  }
  if (message.includes("ETIMEDOUT") || message.includes("timed out")) {
    return "로컬 agent 응답이 시간 안에 오지 않았습니다. agent 상태와 signaling 실행 여부를 다시 확인하세요.";
  }
  return message;
}

function renderMobileBootstrapHtml(nonce: string): string {
  return `<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8" />
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>VibeDeck Mobile Bootstrap</title>
  <style>
    :root { color-scheme: dark; --bg: #0f131b; --panel: #171c27; --line: #2a3140; --text: #edf1ff; --muted: #9ea9c7; --accent: #f4c76e; --warn: #ffb36b; font-family: Consolas, "SFMono-Regular", monospace; }
    * { box-sizing: border-box; }
    body { margin: 0; background: radial-gradient(circle at top, #1f2633, var(--bg)); color: var(--text); }
    button { font: inherit; border: 1px solid var(--line); border-radius: 12px; background: #0d1118; color: var(--text); padding: 10px 14px; cursor: pointer; }
    button.primary { background: linear-gradient(135deg, var(--accent), #ff8c5a); color: #101318; border-color: transparent; font-weight: 700; }
    code, pre { font: inherit; }
    .layout { max-width: 920px; margin: 0 auto; padding: 24px; display: grid; gap: 16px; }
    .card { background: var(--panel); border: 1px solid var(--line); border-radius: 18px; padding: 18px; }
    .hero { display: grid; grid-template-columns: 280px 1fr; gap: 18px; align-items: start; }
    .qr { display: flex; align-items: center; justify-content: center; background: white; border-radius: 18px; padding: 14px; min-height: 280px; }
    .qr svg { width: 100%; max-width: 240px; height: auto; }
    .stack { display: grid; gap: 10px; }
    .title { font-size: 18px; font-weight: 700; }
    .muted { color: var(--muted); font-size: 12px; line-height: 1.5; }
    .pill { display: inline-flex; padding: 6px 10px; border-radius: 999px; border: 1px solid var(--line); background: #0d1118; color: var(--muted); font-size: 12px; }
    .value { padding: 12px; border-radius: 12px; border: 1px solid var(--line); background: #0b0f15; word-break: break-all; }
    .warning { color: var(--warn); }
    .actions { display: flex; gap: 10px; flex-wrap: wrap; }
    @media (max-width: 860px) { .hero { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <div id="app"></div>
  <script nonce="${nonce}">
    const vscode = acquireVsCodeApi();
    let state = {
      bootstrapLink: '',
      qrSvg: '',
      publicAgentBaseUrl: '',
      publicSignalingBaseUrl: '',
      workspaceRoot: '',
      currentThreadId: '',
      currentSessionId: '',
      provider: '',
      hostSource: '',
      warning: '',
    };

    window.addEventListener('message', function(event) {
      const message = event.data;
      if (!message || message.type !== 'state') {
        return;
      }
      state = message.state;
      render();
    });

    document.addEventListener('click', function(event) {
      const target = event.target.closest('[data-action]');
      if (!target) {
        return;
      }
      vscode.postMessage({ type: target.dataset.action });
    });

    render();

    function render() {
      const app = document.getElementById('app');
      if (!app) {
        return;
      }
      app.innerHTML = [
        '<div class="layout">',
        '  <div class="card hero">',
        '    <div class="qr">' + (state.qrSvg || '<div class="muted">QR 생성 대기중</div>') + '</div>',
        '    <div class="stack">',
        '      <div class="title">VibeDeck Mobile Bootstrap</div>',
        '      <div class="muted">휴대폰 카메라로 QR을 스캔하면 앱이 vibedeck://bootstrap 링크를 받아 agent/signaling/thread 기본값을 자동 적용합니다.</div>',
        state.provider ? '<div class="pill">provider ' + esc(state.provider) + '</div>' : '',
        state.hostSource ? '<div class="pill">host ' + esc(state.hostSource) + '</div>' : '',
        state.warning ? '<div class="muted warning">' + esc(state.warning) + '</div>' : '',
        '      <div class="actions"><button class="primary" data-action="copy-link">링크 복사</button><button data-action="refresh">새로고침</button></div>',
        '    </div>',
        '  </div>',
        '  <div class="card stack">',
        '    <div class="title">연결 정보</div>',
        '    <div class="muted">agent</div><div class="value">' + esc(state.publicAgentBaseUrl || '-') + '</div>',
        '    <div class="muted">signaling</div><div class="value">' + esc(state.publicSignalingBaseUrl || '-') + '</div>',
        '    <div class="muted">thread</div><div class="value">' + esc(state.currentThreadId || '-') + '</div>',
        '    <div class="muted">session</div><div class="value">' + esc(state.currentSessionId || '-') + '</div>',
        '    <div class="muted">workspace</div><div class="value">' + esc(state.workspaceRoot || '-') + '</div>',
        '    <div class="muted">deep link</div><div class="value">' + esc(state.bootstrapLink || '-') + '</div>',
        '  </div>',
        '</div>',
      ].join('');
    }

    function esc(value) {
      return String(value || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
    }
  </script>
</body>
</html>`;
}

