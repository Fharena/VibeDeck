import { randomBytes } from "node:crypto";

import type { DisposableLike } from "@vibedeck/cursor-bridge";

import {
  AgentPanelApiError,
  createAgentPanelApi,
  type AgentPanelAdapterRuntime,
  type AgentPanelApi,
  type AgentPanelEnvelope,
  type AgentPanelRunProfile,
  type AgentPanelThreadDetail,
  type AgentPanelThreadEvent,
  type AgentPanelThreadSummary,
} from "./agentPanelApi.js";

export interface ThreadPanelConfigurationLike {
  get<T>(key: string, defaultValue?: T): T;
}

export interface ThreadPanelWorkspaceLike {
  getConfiguration(section?: string): ThreadPanelConfigurationLike;
}

export interface ThreadPanelWebviewLike {
  html: string;
  options?: {
    enableScripts?: boolean;
    retainContextWhenHidden?: boolean;
  };
  onDidReceiveMessage(listener: (message: unknown) => unknown): DisposableLike;
  postMessage(message: unknown): Promise<boolean> | Thenable<boolean>;
}

export interface ThreadPanelWebviewViewLike {
  webview: ThreadPanelWebviewLike;
  title?: string;
  description?: string;
  show?(preserveFocus?: boolean): void;
}

export interface ThreadPanelWebviewViewProviderLike {
  resolveWebviewView(view: ThreadPanelWebviewViewLike): unknown;
}

export interface ThreadPanelWebviewPanelLike extends DisposableLike {
  title: string;
  webview: ThreadPanelWebviewLike;
  reveal(column?: number): void;
  onDidDispose(listener: () => unknown): DisposableLike;
}

export interface ThreadPanelWindowLike {
  activeTextEditor?: unknown;
  onDidChangeActiveTextEditor?(listener: (editor: unknown) => unknown): DisposableLike;
  onDidChangeTextEditorSelection?(listener: (event: unknown) => unknown): DisposableLike;
  registerWebviewViewProvider?(
    viewId: string,
    provider: ThreadPanelWebviewViewProviderLike,
  ): DisposableLike;
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

export interface ThreadPanelVscodeLike {
  commands?: {
    executeCommand<T = unknown>(command: string, ...args: unknown[]): Promise<T>;
  };
  window: ThreadPanelWindowLike;
  workspace: ThreadPanelWorkspaceLike;
  viewColumn: {
    one: number;
  };
}

export interface ThreadPanelController {
  openOrReveal(): Promise<void>;
  refreshIfOpen(): Promise<void>;
  dispose(): void;
}

interface ThreadPanelSettings {
  agentBaseUrl: string;
  autoRefreshMs: number;
}

interface ThreadPanelPatchHunk {
  id: string;
  header: string;
  diff: string;
  risk: string;
}

interface ThreadPanelPatchFile {
  path: string;
  status: string;
  hunks: ThreadPanelPatchHunk[];
}

interface ThreadPanelRunError {
  message: string;
  path: string;
  line: number;
  column: number;
}

interface ThreadPanelDerivedState {
  promptText: string;
  patchSummary: string;
  patchFiles: ThreadPanelPatchFile[];
  patchResultStatus: string;
  patchResultMessage: string;
  patchAvailabilityReason: string;
  currentJobFiles: string[];
  runProfileId: string;
  runStatus: string;
  runSummary: string;
  runExcerpt: string;
  runOutput: string;
  runErrors: ThreadPanelRunError[];
}

interface ThreadPanelViewState {
  agentBaseUrl: string;
  autoRefreshMs: number;
  composeMode: boolean;
  statusMessage: string;
  errorMessage: string;
  refreshedAt: number;
  adapter: AgentPanelAdapterRuntime;
  runProfiles: AgentPanelRunProfile[];
  threads: AgentPanelThreadSummary[];
  selectedThreadId: string;
  currentThread: AgentPanelThreadSummary | null;
  currentJobId: string;
  events: AgentPanelThreadEvent[];
  live: AgentPanelThreadDetail["liveState"];
  operation: AgentPanelThreadDetail["operationState"];
  derived: ThreadPanelDerivedState;
}

interface ThreadPanelMessage {
  type: string;
  threadId?: unknown;
  prompt?: unknown;
  profileId?: unknown;
  path?: unknown;
  line?: unknown;
  column?: unknown;
  contextOptions?: unknown;
}

export function createThreadPanelController(
  vscodeLike: ThreadPanelVscodeLike,
  api: AgentPanelApi = createAgentPanelApi(),
): ThreadPanelController {
  return new DefaultThreadPanelController(vscodeLike, api);
}

class DefaultThreadPanelController implements ThreadPanelController {
  private static readonly sidebarContainerId = "vibedeckBridge";

  private static readonly sidebarViewId = "vibedeckBridge.sharedThreads";

  private readonly vscode: ThreadPanelVscodeLike;
  private readonly api: AgentPanelApi;
  private panel: ThreadPanelWebviewPanelLike | undefined;
  private view: ThreadPanelWebviewViewLike | undefined;
  private readonly viewRegistration: DisposableLike | undefined;
  private refreshTimer: NodeJS.Timeout | undefined;
  private refreshInFlight: Promise<void> | undefined;
  private sessionStream: DisposableLike | undefined;
  private readonly editorSyncDisposables: DisposableLike[] = [];
  private editorSyncTimer: NodeJS.Timeout | undefined;
  private sidebarReadyTimer: NodeJS.Timeout | undefined;
  private sessionStreamSessionId = "";
  private selectedThreadId = "";
  private composeMode = false;
  private viewReady = false;
  private preferPanelHost = false;
  private lastState: ThreadPanelViewState | undefined;
  private lastStatusMessage = "";
  private lastErrorMessage = "";
  private sequence = 1;

  constructor(vscodeLike: ThreadPanelVscodeLike, api: AgentPanelApi) {
    this.vscode = vscodeLike;
    this.api = api;
    this.viewRegistration = this.registerSidebarView();
  }

  async openOrReveal(): Promise<void> {
    if (this.preferPanelHost && this.panel) {
      this.panel.reveal(this.vscode.viewColumn.one);
      await this.refresh();
      return;
    }
    if (this.viewRegistration) {
      await this.revealSidebarView();
      if (this.view?.show) {
        this.view.show(true);
      }
      await this.refreshIfOpen();
      return;
    }
    if (this.panel) {
      this.panel.reveal(this.vscode.viewColumn.one);
      await this.refresh();
      return;
    }

    const panel = this.vscode.window.createWebviewPanel(
      "vibedeckThreads",
      "VibeDeck 세션",
      this.vscode.viewColumn.one,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
      },
    );

    const nonce = randomBytes(16).toString("hex");
    panel.webview.html = renderThreadPanelHtml(nonce);
    panel.onDidDispose(() => {
      this.panel = undefined;
      this.stopRefreshLoop();
      this.stopEditorSync();
      this.stopSessionStream();
    });
    panel.webview.onDidReceiveMessage((message) => {
      void this.handleMessage(message);
    });

    this.panel = panel;
    this.startEditorSync();
    this.restartRefreshLoop();
    await this.refresh();
  }

  async refreshIfOpen(): Promise<void> {
    if (!this.currentHost()) {
      return;
    }
    await this.refresh();
  }

  dispose(): void {
    this.stopRefreshLoop();
    this.stopEditorSync();
    this.stopSessionStream();
    if (this.sidebarReadyTimer) {
      clearTimeout(this.sidebarReadyTimer);
      this.sidebarReadyTimer = undefined;
    }
    this.viewRegistration?.dispose();
    this.view = undefined;
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  private registerSidebarView(): DisposableLike | undefined {
    const registerProvider = this.vscode.window.registerWebviewViewProvider;
    if (typeof registerProvider !== "function") {
      return undefined;
    }
    return registerProvider(DefaultThreadPanelController.sidebarViewId, {
      resolveWebviewView: (view) => {
        this.attachView(view);
      },
    });
  }

  private attachView(view: ThreadPanelWebviewViewLike): void {
    this.view = view;
    this.viewReady = false;
    if (this.panel && !this.preferPanelHost) {
      this.panel.dispose();
      this.panel = undefined;
    }
    view.webview.options = {
      enableScripts: true,
    };
    const nonce = randomBytes(16).toString("hex");
    view.webview.html = renderThreadPanelHtml(nonce);
    view.webview.onDidReceiveMessage((message) => {
      void this.handleMessage(message);
    });
    this.armSidebarReadyFallback();
    this.startEditorSync();
    this.restartRefreshLoop();
    void this.refresh();
  }

  private async revealSidebarView(): Promise<void> {
    const executeCommand = this.vscode.commands?.executeCommand;
    if (typeof executeCommand !== "function") {
      return;
    }
    try {
      await executeCommand(
        `workbench.view.extension.${DefaultThreadPanelController.sidebarContainerId}`,
      );
    } catch {
      // Cursor/VS Code 버전에 따라 컨테이너 reveal command가 다를 수 있어, 실패 시 조용히 폴백한다.
    }
    try {
      await executeCommand(`${DefaultThreadPanelController.sidebarViewId}.focus`);
    } catch {
      // 자동 focus command가 없는 환경에서는 컨테이너 reveal만으로 충분하다.
    }
  }

  private currentHost(): { webview: ThreadPanelWebviewLike; title?: string; description?: string } | undefined {
    if (this.preferPanelHost && this.panel) {
      return this.panel;
    }
    return this.view ?? this.panel;
  }

  private async refresh(): Promise<void> {
    if (!this.currentHost()) {
      return;
    }
    if (this.refreshInFlight) {
      await this.refreshInFlight;
      return;
    }

    this.refreshInFlight = this.refreshCore();
    try {
      await this.refreshInFlight;
    } finally {
      this.refreshInFlight = undefined;
    }
  }

  private async refreshCore(): Promise<void> {
    const host = this.currentHost();
    if (!host) {
      return;
    }

    const settings = this.readSettings();
    this.restartRefreshLoop(settings.autoRefreshMs);

    try {
      const [adapter, runProfiles, threads] = await Promise.all([
        this.api.runtimeAdapter(settings.agentBaseUrl),
        this.api.runProfiles(settings.agentBaseUrl),
        this.api.sessions(settings.agentBaseUrl),
      ]);

      if (this.selectedThreadId && !threads.some((thread) => thread.id === this.selectedThreadId)) {
        this.selectedThreadId = "";
        this.composeMode = false;
      }
      if (!this.composeMode && !this.selectedThreadId && threads.length > 0) {
        this.selectedThreadId = threads[0].id;
      }

      const selectedSessionId = this.resolveSessionID(this.selectedThreadId, threads);
      const detail = selectedSessionId
        ? await this.api.sessionDetail(settings.agentBaseUrl, selectedSessionId)
        : undefined;
      if (detail?.thread.id) {
        this.selectedThreadId = detail.thread.id;
      }

      const state = buildViewState({
        settings,
        adapter,
        runProfiles,
        threads,
        selectedThreadId: this.selectedThreadId,
        composeMode: this.composeMode,
        detail,
        statusMessage: this.lastStatusMessage,
        errorMessage: this.lastErrorMessage,
      });

      this.lastState = state;
      this.updatePanelTitle(state);
      await host.webview.postMessage({ type: "state", state });
      if (detail && !this.composeMode) {
        this.restartSessionStream(settings.agentBaseUrl, detail.thread.sessionId);
        void this.publishSessionPresence(settings.agentBaseUrl, state);
      } else {
        this.stopSessionStream();
      }
    } catch (error) {
      const state = buildFallbackState(
        settings,
        this.lastState,
        describeError(error),
        this.lastStatusMessage,
        this.composeMode,
        this.selectedThreadId,
      );
      this.lastState = state;
      this.updatePanelTitle(state);
      await host.webview.postMessage({ type: "state", state });
    }
  }

  private async handleMessage(rawMessage: unknown): Promise<void> {
    const message = objectValue(rawMessage) as unknown as ThreadPanelMessage;
    try {
      switch (text(message.type)) {
        case "ready":
          this.viewReady = true;
          this.preferPanelHost = false;
          if (this.sidebarReadyTimer) {
            clearTimeout(this.sidebarReadyTimer);
            this.sidebarReadyTimer = undefined;
          }
          return;
        case "refresh":
          await this.refresh();
          return;
        case "new-thread": {
          const previousSessionId = this.currentSessionID();
          if (previousSessionId) {
            await this.clearSessionComposer(this.readSettings().agentBaseUrl, previousSessionId);
          }
          this.composeMode = true;
          this.selectedThreadId = "";
          this.stopSessionStream();
          this.lastStatusMessage = "새 스레드를 작성 중입니다.";
          this.lastErrorMessage = "";
          await this.refresh();
          return;
        }
        case "select-thread": {
          const previousSessionId = this.currentSessionID();
          const nextThreadId = text(message.threadId);
          if (previousSessionId && this.currentThreadID() !== nextThreadId) {
            await this.clearSessionComposer(this.readSettings().agentBaseUrl, previousSessionId);
          }
          this.composeMode = false;
          this.selectedThreadId = nextThreadId;
          this.lastStatusMessage = "";
          this.lastErrorMessage = "";
          await this.refresh();
          return;
        }
        case "submit-prompt":
          await this.submitPrompt(message);
          return;
        case "update-draft":
          await this.updateDraft(text(message.prompt));
          return;
        case "apply-patch":
          await this.applyPatch();
          return;
        case "run-profile":
          await this.runProfile(text(message.profileId));
          return;
        case "open-location":
          await this.openLocation(message);
          return;
        default:
          return;
      }
    } catch (error) {
      this.lastErrorMessage = describeError(error);
      this.lastStatusMessage = "";
      this.vscode.window.showErrorMessage(this.lastErrorMessage);
      await this.refresh();
    }
  }

  private async submitPrompt(message: ThreadPanelMessage): Promise<void> {
    const prompt = text(message.prompt).trim();
    if (!prompt) {
      this.vscode.window.showWarningMessage("프롬프트를 입력하세요.");
      return;
    }

    const settings = this.readSettings();
    const envelope = this.newEnvelope(this.currentSessionID(), "PROMPT_SUBMIT", {
      threadId: this.composeMode ? undefined : this.selectedThreadId || undefined,
      prompt,
      contextOptions: sanitizeContextOptions(message.contextOptions),
    });

    this.lastErrorMessage = "";
    const wasComposeMode = this.composeMode;
    const responses = await this.sendEnvelopeAndRecover(settings.agentBaseUrl, envelope);
    this.applyEnvelopeResponses(responses);
    this.composeMode = false;
    const sessionId = !wasComposeMode ? this.currentSessionID() : "";
    if (sessionId) {
      await this.clearSessionComposer(settings.agentBaseUrl, sessionId);
    }
    if (!this.lastErrorMessage) {
      this.lastStatusMessage = "프롬프트를 전송했습니다.";
    }
    await this.refresh();
  }

  private async applyPatch(): Promise<void> {
    const currentJobId = this.lastState?.currentJobId ?? "";
    const patchFiles = this.lastState?.derived.patchFiles ?? [];
    if (!currentJobId || patchFiles.length === 0) {
      const message =
        this.lastState?.derived.patchAvailabilityReason ||
        "적용할 패치가 없습니다. 먼저 프롬프트를 실행하세요.";
      this.vscode.window.showWarningMessage(message);
      return;
    }

    const settings = this.readSettings();
    const envelope = this.newEnvelope(this.currentSessionID(), "PATCH_APPLY", {
      jobId: currentJobId,
      mode: "all",
    });

    this.lastErrorMessage = "";
    const responses = await this.sendEnvelopeAndRecover(settings.agentBaseUrl, envelope);
    this.applyEnvelopeResponses(responses);
    if (!this.lastErrorMessage) {
      this.lastStatusMessage = "패치 적용을 요청했습니다.";
    }
    await this.refresh();
  }

  private async runProfile(profileID: string): Promise<void> {
    const normalizedProfileID = profileID.trim();
    if (!normalizedProfileID) {
      this.vscode.window.showWarningMessage("실행 프로파일을 선택하세요.");
      return;
    }

    const currentJobId = this.lastState?.currentJobId ?? "";
    if (!currentJobId) {
      this.vscode.window.showWarningMessage("실행할 작업이 없습니다. 먼저 프롬프트를 실행하세요.");
      return;
    }

    const settings = this.readSettings();
    const envelope = this.newEnvelope(this.currentSessionID(), "RUN_PROFILE", {
      jobId: currentJobId,
      profileId: normalizedProfileID,
    });

    this.lastErrorMessage = "";
    const responses = await this.sendEnvelopeAndRecover(settings.agentBaseUrl, envelope);
    this.applyEnvelopeResponses(responses);
    if (!this.lastErrorMessage) {
      this.lastStatusMessage = "프로파일 실행을 요청했습니다: " + normalizedProfileID;
    }
    await this.refresh();
  }

  private async openLocation(message: ThreadPanelMessage): Promise<void> {
    const targetPath = text(message.path).trim();
    if (!targetPath) {
      return;
    }

    const settings = this.readSettings();
    const envelope = this.newEnvelope(this.currentSessionID(), "OPEN_LOCATION", {
      path: targetPath,
      line: numberValue(message.line),
      column: numberValue(message.column),
    });

    this.lastErrorMessage = "";
    const responses = await this.sendEnvelopeAndRecover(settings.agentBaseUrl, envelope);
    this.applyEnvelopeResponses(responses);
    if (!this.lastErrorMessage) {
      this.lastStatusMessage = "위치를 열었습니다: " + targetPath;
    }
    await this.refresh();
  }

  private newEnvelope(
    sid: string,
    type: string,
    payload: Record<string, unknown>,
  ): AgentPanelEnvelope {
    const seq = this.sequence;
    this.sequence += 1;
    return {
      sid,
      rid: `rid_panel_${type.toLowerCase()}_${seq}`,
      seq,
      ts: Date.now(),
      type,
      payload: compactObject(payload),
    };
  }

  private async updateDraft(prompt: string): Promise<void> {
    if (this.composeMode) {
      return;
    }
    const sessionId = this.currentSessionID();
    if (!sessionId) {
      return;
    }

    const settings = this.readSettings();
    await this.publishSessionLiveState(settings.agentBaseUrl, sessionId, {
      composer: {
        draftText: prompt,
        isTyping: prompt.trim().length > 0,
        updatedAt: Date.now(),
      },
    });
  }

  private currentThreadID(): string {
    return this.selectedThreadId || this.lastState?.currentThread?.id || "";
  }

  private currentSessionID(): string {
    return (
      this.resolveSessionID(this.currentThreadID(), this.lastState?.threads ?? []) ||
      this.lastState?.currentThread?.sessionId ||
      "sid-vibedeck-panel"
    );
  }

  private resolveSessionID(
    threadId: string,
    threads: AgentPanelThreadSummary[],
  ): string {
    if (!threadId) {
      return "";
    }
    const selected = threads.find((thread) => thread.id === threadId);
    if (selected?.sessionId) {
      return selected.sessionId;
    }
    if (this.lastState?.currentThread?.id === threadId) {
      return this.lastState.currentThread.sessionId || "";
    }
    return "";
  }

  private restartSessionStream(baseUrl: string, sessionId: string): void {
    if (!sessionId) {
      this.stopSessionStream();
      return;
    }
    if (
      this.sessionStream &&
      this.sessionStreamSessionId === sessionId
    ) {
      return;
    }

    this.stopSessionStream();
    this.sessionStreamSessionId = sessionId;
    this.sessionStream = this.api.subscribeSession(
      baseUrl,
      sessionId,
      (detail) => {
        this.applySessionSnapshot(detail);
      },
      () => {
        if (this.sessionStreamSessionId !== sessionId) {
          return;
        }
        this.stopSessionStream();
      },
    );
  }

  private stopSessionStream(): void {
    this.sessionStreamSessionId = "";
    this.sessionStream?.dispose();
    this.sessionStream = undefined;
  }

  private startEditorSync(): void {
    this.stopEditorSync();

    const onDidChangeActiveTextEditor = this.vscode.window.onDidChangeActiveTextEditor;
    if (typeof onDidChangeActiveTextEditor === "function") {
      this.editorSyncDisposables.push(
        onDidChangeActiveTextEditor(() => {
          this.scheduleEditorSync();
        }),
      );
    }

    const onDidChangeTextEditorSelection = this.vscode.window.onDidChangeTextEditorSelection;
    if (typeof onDidChangeTextEditorSelection === "function") {
      this.editorSyncDisposables.push(
        onDidChangeTextEditorSelection(() => {
          this.scheduleEditorSync();
        }),
      );
    }
  }

  private stopEditorSync(): void {
    if (this.editorSyncTimer) {
      clearTimeout(this.editorSyncTimer);
      this.editorSyncTimer = undefined;
    }
    while (this.editorSyncDisposables.length > 0) {
      this.editorSyncDisposables.pop()?.dispose();
    }
  }

  private scheduleEditorSync(): void {
    if (!this.currentHost() || this.composeMode) {
      return;
    }
    if (this.editorSyncTimer) {
      clearTimeout(this.editorSyncTimer);
    }
    this.editorSyncTimer = setTimeout(() => {
      this.editorSyncTimer = undefined;
      void this.syncActiveEditorPresence();
    }, 150);
  }

  private async syncActiveEditorPresence(): Promise<void> {
    const state = this.lastState;
    if (!state || this.composeMode || !state.currentThread?.sessionId) {
      return;
    }
    await this.publishSessionPresence(state.agentBaseUrl, state);
  }

  private applySessionSnapshot(detail: AgentPanelThreadDetail): void {
    const host = this.currentHost();
    if (!host) {
      return;
    }

    this.selectedThreadId = detail.thread.id;
    const previous = this.lastState;
    const settings = this.readSettings();
    const nextState = buildViewState({
      settings: {
        agentBaseUrl: previous?.agentBaseUrl || settings.agentBaseUrl,
        autoRefreshMs: previous?.autoRefreshMs || settings.autoRefreshMs,
      },
      adapter: previous?.adapter ?? {
        name: "",
        mode: "",
        ready: false,
        workspaceRoot: "",
        binaryPath: "",
        notes: [],
      },
      runProfiles: previous?.runProfiles ?? [],
      threads: previous?.threads ?? [],
      selectedThreadId: detail.thread.id,
      composeMode: false,
      detail,
      statusMessage: this.lastStatusMessage,
      errorMessage: this.lastErrorMessage,
    });

    this.lastState = nextState;
    this.updatePanelTitle(nextState);
    void host.webview.postMessage({ type: "state", state: nextState });
  }

  private async publishSessionPresence(
    baseUrl: string,
    state: ThreadPanelViewState,
  ): Promise<void> {
    const currentThread = state.currentThread;
    if (!currentThread?.sessionId) {
      return;
    }
    const updatedAt = Date.now();
    const activeEditorFocus = readActiveEditorFocus(this.vscode.window.activeTextEditor);
    const focus = buildFocusPresenceUpdate(state, activeEditorFocus, updatedAt);
    const workspace = buildWorkspacePresenceUpdate(state, focus, updatedAt);
    const update: Record<string, unknown> = {
      participant: {
        participantId: "cursor-panel",
        clientType: "cursor_panel",
        displayName: "Cursor Panel",
        active: true,
        lastSeenAt: updatedAt,
      },
      activity: {
        phase: firstNonEmptyText(state.operation.phase, currentThread.state),
        summary: sessionPresenceSummary(state),
        updatedAt,
      },
    };

    if (focus) {
      update.focus = focus;
    }
    if (workspace) {
      update.workspace = workspace;
    }

    await this.publishSessionLiveState(baseUrl, currentThread.sessionId, update);
  }

  private async clearSessionComposer(baseUrl: string, sessionId: string): Promise<void> {
    await this.publishSessionLiveState(baseUrl, sessionId, {
      composer: {
        draftText: "",
        isTyping: false,
        updatedAt: Date.now(),
      },
    });
  }

  private async publishSessionLiveState(
    baseUrl: string,
    sessionId: string,
    update: Record<string, unknown>,
  ): Promise<void> {
    if (!sessionId) {
      return;
    }
    const detail = await this.api.updateSessionLiveState(baseUrl, sessionId, update);
    this.applySessionSnapshot(detail);
  }

  private async sendEnvelopeAndRecover(
    baseUrl: string,
    envelope: AgentPanelEnvelope,
  ): Promise<Record<string, unknown>[]> {
    try {
      const result = await this.api.sendEnvelope(baseUrl, envelope);
      return result.responses;
    } catch (error) {
      if (error instanceof AgentPanelApiError) {
        const recovered = extractResponsesFromBody(error.responseBody);
        if (recovered.length > 0) {
          return recovered;
        }
      }
      throw error;
    }
  }

  private applyEnvelopeResponses(responses: Record<string, unknown>[]): void {
    for (const response of responses) {
      const responseType = text(response.type);
      const payload = objectValue(response.payload);
      if (responseType === "CMD_ACK") {
        if (payload.accepted !== true) {
          this.lastErrorMessage =
            text(payload.message) || "agent 요청을 처리하지 못했습니다.";
        }
        continue;
      }
      if (responseType === "PROMPT_ACK") {
        const threadID = text(payload.threadId);
        if (threadID) {
          this.selectedThreadId = threadID;
          this.composeMode = false;
        }
        this.lastErrorMessage = "";
        continue;
      }
      if (responseType === "PATCH_READY") {
        this.lastErrorMessage = "";
        continue;
      }
      if (responseType === "PATCH_RESULT") {
        const status = text(payload.status).toLowerCase();
        if (status === "failed") {
          this.lastErrorMessage =
            text(payload.message) || "패치 적용에 실패했습니다.";
        } else {
          this.lastErrorMessage = "";
        }
        continue;
      }
      if (responseType === "RUN_RESULT") {
        const status = text(payload.status).toLowerCase();
        if (status === "failed") {
          this.lastErrorMessage =
            text(payload.summary) ||
            text(payload.message) ||
            "프로파일 실행에 실패했습니다.";
        } else {
          this.lastErrorMessage = "";
        }
      }
    }
  }

  private readSettings(): ThreadPanelSettings {
    const config = this.vscode.workspace.getConfiguration("vibedeckBridge");
    const configuredAgentBaseUrl = text(config.get<string>("agentBaseUrl", "")).trim();
    const agentHost = text(config.get<string>("agent.host", "127.0.0.1")).trim() || "127.0.0.1";
    const agentPort = normalizePortValue(config.get<number>("agent.port", 8080), 8080);
    return {
      agentBaseUrl:
        configuredAgentBaseUrl ||
        normalizeAgentBaseUrl(agentHost, agentPort),
      autoRefreshMs: normalizeRefreshMs(config.get<number>("panelAutoRefreshMs", 4000)),
    };
  }

  private restartRefreshLoop(intervalMs?: number): void {
    const effectiveIntervalMs = intervalMs ?? this.readSettings().autoRefreshMs;
    const currentInterval = (this.refreshTimer as unknown as { _idleTimeout?: number } | undefined)?._idleTimeout;
    if (this.refreshTimer && currentInterval === effectiveIntervalMs) {
      return;
    }

    this.stopRefreshLoop();
    this.refreshTimer = setInterval(() => {
      void this.refresh();
    }, effectiveIntervalMs);
  }

  private stopRefreshLoop(): void {
    if (this.refreshTimer) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = undefined;
    }
  }

  private armSidebarReadyFallback(): void {
    if (!this.view) {
      return;
    }
    if (this.sidebarReadyTimer) {
      clearTimeout(this.sidebarReadyTimer);
    }
    this.sidebarReadyTimer = setTimeout(() => {
      if (!this.view || this.viewReady) {
        return;
      }
      void this.openFallbackPanel(
        "Cursor 사이드바 렌더러가 응답하지 않아 편집기 패널로 전환했습니다.",
      );
    }, 1200);
  }

  private async openFallbackPanel(statusMessage: string): Promise<void> {
    if (this.panel) {
      this.preferPanelHost = true;
      this.lastStatusMessage = statusMessage;
      this.panel.reveal(this.vscode.viewColumn.one);
      await this.refresh();
      return;
    }

    const panel = this.vscode.window.createWebviewPanel(
      "vibedeckThreadsFallback",
      "VibeDeck 세션",
      this.vscode.viewColumn.one,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
      },
    );

    const nonce = randomBytes(16).toString("hex");
    panel.webview.html = renderThreadPanelHtml(nonce);
    panel.onDidDispose(() => {
      if (this.panel === panel) {
        this.panel = undefined;
        this.preferPanelHost = false;
      }
    });
    panel.webview.onDidReceiveMessage((message) => {
      void this.handleMessage(message);
    });

    this.panel = panel;
    this.preferPanelHost = true;
    this.lastStatusMessage = statusMessage;
    this.startEditorSync();
    this.restartRefreshLoop();
    await this.refresh();
  }

  private updatePanelTitle(state: ThreadPanelViewState): void {
    if (!this.currentHost()) {
      return;
    }
    const title = state.composeMode
      ? "새 스레드"
      : state.currentThread?.title || "세션";
    if (this.panel) {
      this.panel.title = `VibeDeck: ${title}`;
      return;
    }
    if (this.view) {
      this.view.description = title;
    }
  }
}

function buildViewState(input: {
  settings: ThreadPanelSettings;
  adapter: AgentPanelAdapterRuntime;
  runProfiles: AgentPanelRunProfile[];
  threads: AgentPanelThreadSummary[];
  selectedThreadId: string;
  composeMode: boolean;
  detail?: AgentPanelThreadDetail;
  statusMessage: string;
  errorMessage: string;
}): ThreadPanelViewState {
  const currentThread = input.detail?.thread ?? null;
  const liveState = normalizeSessionLiveState(input.detail?.liveState);
  const operationState = normalizeSessionOperationState(input.detail?.operationState);
  return {
    agentBaseUrl: input.settings.agentBaseUrl,
    autoRefreshMs: input.settings.autoRefreshMs,
    composeMode: input.composeMode,
    statusMessage: input.statusMessage,
    errorMessage: input.errorMessage,
    refreshedAt: Date.now(),
    adapter: input.adapter,
    runProfiles: input.runProfiles,
    threads: input.threads,
    selectedThreadId: input.selectedThreadId,
    currentThread,
    currentJobId: currentThread?.currentJobId || operationState.currentJobId || "",
    events: input.detail?.events ?? [],
    live: liveState,
    operation: operationState,
    derived: deriveThreadState(input.detail, input.errorMessage),
  };
}
function buildFallbackState(
  settings: ThreadPanelSettings,
  previous: ThreadPanelViewState | undefined,
  errorMessage: string,
  statusMessage: string,
  composeMode: boolean,
  selectedThreadId: string,
): ThreadPanelViewState {
  if (!previous) {
    return {
      agentBaseUrl: settings.agentBaseUrl,
      autoRefreshMs: settings.autoRefreshMs,
      composeMode,
      statusMessage,
      errorMessage,
      refreshedAt: Date.now(),
      adapter: { name: "", mode: "", ready: false, workspaceRoot: "", binaryPath: "", notes: [] },
      runProfiles: [],
      threads: [],
      selectedThreadId,
      currentThread: null,
      currentJobId: "",
      events: [],
      live: emptySessionLiveState(),
      operation: emptySessionOperationState(),
      derived: emptyDerivedState(),
    };
  }
  return {
    ...previous,
    agentBaseUrl: settings.agentBaseUrl,
    autoRefreshMs: settings.autoRefreshMs,
    composeMode,
    statusMessage,
    errorMessage,
    refreshedAt: Date.now(),
    selectedThreadId,
  };
}

function deriveThreadState(
  detail: AgentPanelThreadDetail | undefined,
  errorMessage: string,
): ThreadPanelDerivedState {
  const state = emptyDerivedState();
  if (!detail) {
    return state;
  }

  const currentJobId = detail.thread.currentJobId;
  let sawPromptAccepted = false;

  for (const event of detail.events) {
    if (event.kind === "prompt_submitted" && event.body.trim()) {
      state.promptText = event.body;
      continue;
    }
    if (
      event.kind === "prompt_accepted" &&
      (!currentJobId || event.jobId === currentJobId)
    ) {
      sawPromptAccepted = true;
      continue;
    }
    if (event.kind === "patch_ready") {
      state.patchSummary = text(event.data.summary) || event.body;
      state.patchFiles = parsePatchFiles(event.data.files);
      continue;
    }
    if (event.kind === "patch_applied") {
      state.patchResultStatus = text(event.data.status);
      state.patchResultMessage = event.body || text(event.data.message);
      continue;
    }
    if (event.kind === "run_finished") {
      state.runProfileId = text(event.data.profileId);
      state.runStatus = text(event.data.status);
      state.runSummary = text(event.data.summary) || event.body;
      state.runExcerpt = text(event.data.excerpt);
      state.runOutput = text(event.data.output) || state.runExcerpt;
      state.currentJobFiles = parseStringList(event.data.changedFiles);
      state.runErrors = parseRunErrors(event.data.topErrors);
    }
  }

  if (state.currentJobFiles.length === 0) {
    state.currentJobFiles = patchFilePaths(state.patchFiles);
  }

  state.patchAvailabilityReason = patchAvailabilityReason({
    currentJobId,
    patchFiles: state.patchFiles,
    patchSummary: state.patchSummary,
    errorMessage,
    sawPromptAccepted,
  });

  return state;
}

function emptySessionLiveState(): AgentPanelThreadDetail["liveState"] {
  return {
    participants: [],
    composer: { draftText: "", isTyping: false, updatedAt: 0 },
    focus: {
      activeFilePath: "",
      selection: "",
      patchPath: "",
      runErrorPath: "",
      runErrorLine: 0,
      updatedAt: 0,
    },
    activity: { phase: "", summary: "", updatedAt: 0 },
    reasoning: { title: "", summary: "", sourceKind: "", updatedAt: 0 },
    plan: { summary: "", items: [], updatedAt: 0 },
    tools: { currentLabel: "", currentStatus: "", activities: [], updatedAt: 0 },
    terminal: {
      status: "",
      profileId: "",
      label: "",
      command: "",
      summary: "",
      excerpt: "",
      output: "",
      updatedAt: 0,
    },
    workspace: {
      rootPath: "",
      activeFilePath: "",
      patchFiles: [],
      changedFiles: [],
      updatedAt: 0,
    },
  };
}

function emptySessionOperationState(): AgentPanelThreadDetail["operationState"] {
  return {
    currentJobId: "",
    phase: "",
    patchSummary: "",
    patchFileCount: 0,
    patchFiles: [],
    patchResultStatus: "",
    patchResultMessage: "",
    runProfileId: "",
    runLabel: "",
    runCommand: "",
    runStatus: "",
    runSummary: "",
    runExcerpt: "",
    runOutput: "",
    runChangedFiles: [],
    runTopErrors: [],
    currentJobFiles: [],
    lastError: "",
  };
}

function normalizeSessionLiveState(
  value: AgentPanelThreadDetail["liveState"] | undefined,
): AgentPanelThreadDetail["liveState"] {
  const fallback = emptySessionLiveState();
  const input = objectValue(value);
  const composer = objectValue(input.composer);
  const focus = objectValue(input.focus);
  const activity = objectValue(input.activity);
  const reasoning = objectValue(input.reasoning);
  const plan = objectValue(input.plan);
  const tools = objectValue(input.tools);
  const terminal = objectValue(input.terminal);
  const workspace = objectValue(input.workspace);
  return {
    participants: objectArray(input.participants).map((item) => ({
      participantId: text(item.participantId),
      clientType: text(item.clientType),
      displayName: text(item.displayName),
      active: item.active === true,
      lastSeenAt: numberValue(item.lastSeenAt),
    })),
    composer: {
      draftText: firstNonEmptyText(text(composer.draftText), fallback.composer.draftText),
      isTyping: composer.isTyping === true,
      updatedAt: numberValue(composer.updatedAt) || fallback.composer.updatedAt,
    },
    focus: {
      activeFilePath: firstNonEmptyText(text(focus.activeFilePath), fallback.focus.activeFilePath),
      selection: firstNonEmptyText(text(focus.selection), fallback.focus.selection),
      patchPath: firstNonEmptyText(text(focus.patchPath), fallback.focus.patchPath),
      runErrorPath: firstNonEmptyText(text(focus.runErrorPath), fallback.focus.runErrorPath),
      runErrorLine: numberValue(focus.runErrorLine) || fallback.focus.runErrorLine,
      updatedAt: numberValue(focus.updatedAt) || fallback.focus.updatedAt,
    },
    activity: {
      phase: firstNonEmptyText(text(activity.phase), fallback.activity.phase),
      summary: firstNonEmptyText(text(activity.summary), fallback.activity.summary),
      updatedAt: numberValue(activity.updatedAt) || fallback.activity.updatedAt,
    },
    reasoning: {
      title: firstNonEmptyText(text(reasoning.title), fallback.reasoning.title),
      summary: firstNonEmptyText(text(reasoning.summary), fallback.reasoning.summary),
      sourceKind: firstNonEmptyText(text(reasoning.sourceKind), fallback.reasoning.sourceKind),
      updatedAt: numberValue(reasoning.updatedAt) || fallback.reasoning.updatedAt,
    },
    plan: {
      summary: firstNonEmptyText(text(plan.summary), fallback.plan.summary),
      items: objectArray(plan.items).map((item) => ({
        id: text(item.id),
        label: text(item.label),
        status: text(item.status),
        detail: text(item.detail),
        updatedAt: numberValue(item.updatedAt),
      })),
      updatedAt: numberValue(plan.updatedAt) || fallback.plan.updatedAt,
    },
    tools: {
      currentLabel: firstNonEmptyText(text(tools.currentLabel), fallback.tools.currentLabel),
      currentStatus: firstNonEmptyText(text(tools.currentStatus), fallback.tools.currentStatus),
      activities: objectArray(tools.activities).map((item) => ({
        kind: text(item.kind),
        label: text(item.label),
        status: text(item.status),
        detail: text(item.detail),
        at: numberValue(item.at),
      })),
      updatedAt: numberValue(tools.updatedAt) || fallback.tools.updatedAt,
    },
    terminal: {
      status: firstNonEmptyText(text(terminal.status), fallback.terminal.status),
      profileId: firstNonEmptyText(text(terminal.profileId), fallback.terminal.profileId),
      label: firstNonEmptyText(text(terminal.label), fallback.terminal.label),
      command: firstNonEmptyText(text(terminal.command), fallback.terminal.command),
      summary: firstNonEmptyText(text(terminal.summary), fallback.terminal.summary),
      excerpt: firstNonEmptyText(text(terminal.excerpt), fallback.terminal.excerpt),
      output: firstNonEmptyText(text(terminal.output), fallback.terminal.output),
      updatedAt: numberValue(terminal.updatedAt) || fallback.terminal.updatedAt,
    },
    workspace: {
      rootPath: firstNonEmptyText(text(workspace.rootPath), fallback.workspace.rootPath),
      activeFilePath: firstNonEmptyText(text(workspace.activeFilePath), fallback.workspace.activeFilePath),
      patchFiles: parseStringList(workspace.patchFiles),
      changedFiles: parseStringList(workspace.changedFiles),
      updatedAt: numberValue(workspace.updatedAt) || fallback.workspace.updatedAt,
    },
  };
}

function normalizeSessionOperationState(
  value: AgentPanelThreadDetail["operationState"] | undefined,
): AgentPanelThreadDetail["operationState"] {
  const fallback = emptySessionOperationState();
  const input = objectValue(value);
  return {
    currentJobId: firstNonEmptyText(text(input.currentJobId), fallback.currentJobId),
    phase: firstNonEmptyText(text(input.phase), fallback.phase),
    patchSummary: firstNonEmptyText(text(input.patchSummary), fallback.patchSummary),
    patchFileCount: numberValue(input.patchFileCount) || fallback.patchFileCount,
    patchFiles: parseStringList(input.patchFiles),
    patchResultStatus: firstNonEmptyText(text(input.patchResultStatus), fallback.patchResultStatus),
    patchResultMessage: firstNonEmptyText(text(input.patchResultMessage), fallback.patchResultMessage),
    runProfileId: firstNonEmptyText(text(input.runProfileId), fallback.runProfileId),
    runLabel: firstNonEmptyText(text(input.runLabel), fallback.runLabel),
    runCommand: firstNonEmptyText(text(input.runCommand), fallback.runCommand),
    runStatus: firstNonEmptyText(text(input.runStatus), fallback.runStatus),
    runSummary: firstNonEmptyText(text(input.runSummary), fallback.runSummary),
    runExcerpt: firstNonEmptyText(text(input.runExcerpt), fallback.runExcerpt),
    runOutput: firstNonEmptyText(text(input.runOutput), fallback.runOutput),
    runChangedFiles: parseStringList(input.runChangedFiles),
    runTopErrors: objectArray(input.runTopErrors).map((item) => ({
      path: text(item.path),
      line: numberValue(item.line),
      message: text(item.message),
    })),
    currentJobFiles: parseStringList(input.currentJobFiles),
    lastError: firstNonEmptyText(text(input.lastError), fallback.lastError),
  };
}

function emptyDerivedState(): ThreadPanelDerivedState {
  return {
    promptText: "",
    patchSummary: "",
    patchFiles: [],
    patchResultStatus: "",
    patchResultMessage: "",
    patchAvailabilityReason: "",
    currentJobFiles: [],
    runProfileId: "",
    runStatus: "",
    runSummary: "",
    runExcerpt: "",
    runOutput: "",
    runErrors: [],
  };
}

function parsePatchFiles(value: unknown): ThreadPanelPatchFile[] {
  return objectArray(value).map((file) => ({
    path: text(file.path),
    status: text(file.status),
    hunks: objectArray(file.hunks).map((hunk) => ({
      id: text(hunk.hunkId),
      header: text(hunk.header),
      diff: text(hunk.diff),
      risk: text(hunk.risk),
    })),
  }));
}

function parseRunErrors(value: unknown): ThreadPanelRunError[] {
  return objectArray(value).map((item) => ({
    message: text(item.message),
    path: text(item.path),
    line: numberValue(item.line),
    column: numberValue(item.column),
  }));
}

function parseStringList(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.map((item) => text(item)).filter((item) => item.length > 0);
}

function patchFilePaths(files: ThreadPanelPatchFile[]): string[] {
  return files.map((file) => file.path).filter((item) => item.length > 0);
}

function uniqueNonEmptyStrings(...items: Array<readonly string[] | string | undefined>): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const item of items) {
    if (!item) {
      continue;
    }
    const values = Array.isArray(item) ? item : [item];
    for (const raw of values) {
      const value = text(raw).trim();
      if (!value || seen.has(value)) {
        continue;
      }
      seen.add(value);
      result.push(value);
    }
  }
  return result;
}

function firstNonEmptyText(...items: Array<string | undefined>): string {
  for (const item of items) {
    const value = text(item).trim();
    if (value) {
      return value;
    }
  }
  return "";
}

function patchAvailabilityReason(input: {
  currentJobId: string;
  patchFiles: ThreadPanelPatchFile[];
  patchSummary: string;
  errorMessage: string;
  sawPromptAccepted: boolean;
}): string {
  if (input.patchFiles.length > 0) {
    return "";
  }
  if (!input.currentJobId.trim()) {
    return "먼저 프롬프트를 보내 작업을 시작하세요.";
  }

  const normalizedSummary = input.patchSummary.trim();
  if (normalizedSummary) {
    if (normalizedSummary.toLowerCase().includes("without code changes")) {
      return "이 작업은 코드 변경 없이 완료되어 적용할 파일이 없습니다.";
    }
    return "적용할 파일 패치가 없습니다. " + normalizedSummary;
  }

  const normalizedError = input.errorMessage.trim();
  if (normalizedError) {
    return "패치를 만들지 못했습니다. " + normalizedError;
  }

  if (input.sawPromptAccepted) {
    return "패치가 아직 준비되지 않았거나 코드 변경이 없었습니다.";
  }

  return "적용할 패치가 없습니다.";
}

function sanitizeContextOptions(value: unknown): Record<string, boolean> {
  const input = objectValue(value);
  return {
    includeActiveFile: input.includeActiveFile === true,
    includeSelection: input.includeSelection === true,
    includeLatestError: input.includeLatestError === true,
    includeWorkspaceSummary: input.includeWorkspaceSummary === true,
  };
}

function compactObject(value: Record<string, unknown>): Record<string, unknown> {
  const next: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    if (item !== undefined) {
      next[key] = item;
    }
  }
  return next;
}

function extractResponsesFromBody(body: Record<string, unknown> | null): Record<string, unknown>[] {
  if (!body) {
    return [];
  }
  return objectArray(body.responses);
}

function describeError(error: unknown): string {
  if (error instanceof AgentPanelApiError) {
    return error.statusCode > 0 ? `[${error.statusCode}] ${error.message}` : error.message;
  }
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}

function readActiveEditorFocus(editor: unknown): Record<string, unknown> | null {
  const editorValue = objectValue(editor);
  const documentValue = objectValue(editorValue.document);
  const uriValue = objectValue(documentValue.uri);
  const focusPath = text(uriValue.fsPath) || text(documentValue.fileName);
  const selectionValue = objectValue(editorValue.selection);
  const startValue = objectValue(selectionValue.start);
  const endValue = objectValue(selectionValue.end);

  const parts: string[] = [];
  const hasStart = typeof startValue.line === "number" || typeof startValue.character === "number";
  const hasEnd = typeof endValue.line === "number" || typeof endValue.character === "number";
  if (hasStart) {
    parts.push(`${numberValue(startValue.line) + 1}:${numberValue(startValue.character) + 1}`);
  }
  if (hasEnd &&
      (numberValue(endValue.line) !== numberValue(startValue.line) ||
        numberValue(endValue.character) !== numberValue(startValue.character))) {
    parts.push(`${numberValue(endValue.line) + 1}:${numberValue(endValue.character) + 1}`);
  }

  if (!focusPath && parts.length === 0) {
    return null;
  }

  return compactObject({
    activeFilePath: focusPath,
    selection: parts.join(' -> '),
    updatedAt: Date.now(),
  });
}

function buildFocusPresenceUpdate(
  state: ThreadPanelViewState,
  editorFocus: Record<string, unknown> | null,
  updatedAt: number,
): Record<string, unknown> | null {
  const liveFocus = state.live.focus;
  const focusValue = objectValue(editorFocus);
  const activeFilePath = firstNonEmptyText(
    text(focusValue.activeFilePath),
    liveFocus.activeFilePath,
  );
  const selection = firstNonEmptyText(
    text(focusValue.selection),
    liveFocus.selection,
  );
  const patchPath = liveFocus.patchPath.trim();
  const runErrorPath = liveFocus.runErrorPath.trim();
  const runErrorLine = numberValue(liveFocus.runErrorLine);

  if (!activeFilePath && !selection && !patchPath && !runErrorPath && runErrorLine === 0) {
    return null;
  }

  return {
    activeFilePath,
    selection,
    patchPath,
    runErrorPath,
    runErrorLine,
    updatedAt,
  };
}

function buildWorkspacePresenceUpdate(
  state: ThreadPanelViewState,
  focus: Record<string, unknown> | null,
  updatedAt: number,
): Record<string, unknown> | null {
  const liveWorkspace = state.live.workspace;
  const focusValue = objectValue(focus);
  const focusPatchPath = text(focusValue.patchPath).trim();
  const activeFilePath = firstNonEmptyText(
    text(focusValue.activeFilePath),
    liveWorkspace.activeFilePath,
    focusPatchPath,
    text(focusValue.runErrorPath),
  );
  const patchFiles = uniqueNonEmptyStrings(
    patchFilePaths(state.derived.patchFiles),
    state.operation.patchFiles,
    liveWorkspace.patchFiles,
    focusPatchPath,
  );
  const changedFiles = uniqueNonEmptyStrings(
    state.operation.runChangedFiles,
    state.derived.currentJobFiles,
    liveWorkspace.changedFiles,
  );
  const rootPath = firstNonEmptyText(liveWorkspace.rootPath, state.adapter.workspaceRoot);

  if (!rootPath && !activeFilePath && patchFiles.length === 0 && changedFiles.length === 0) {
    return null;
  }

  return {
    rootPath,
    activeFilePath,
    patchFiles,
    changedFiles,
    updatedAt,
  };
}

function sessionPresenceSummary(state: ThreadPanelViewState): string {
  const promptText = firstNonEmptyText(
    state.live.composer.draftText,
    state.derived.promptText,
  );
  if (promptText) {
    return "Cursor 패널에서 프롬프트 작성 중";
  }
  return firstNonEmptyText(
    state.live.activity.summary,
    state.currentThread?.lastEventText,
    state.currentJobId ? "Cursor 패널에서 작업 상태를 확인 중입니다." : "Cursor 패널에서 세션을 보고 있습니다.",
  );
}

function normalizeRefreshMs(value: number): number {
  if (!Number.isFinite(value) || value < 1000) {
    return 4000;
  }
  return Math.trunc(value);
}

function normalizePortValue(value: number, fallback: number): number {
  if (!Number.isFinite(value) || value < 1 || value > 65535) {
    return fallback;
  }
  return Math.trunc(value);
}

function normalizeAgentBaseUrl(host: string, port: number): string {
  const safeHost = host === "0.0.0.0" || host === "::" ? "127.0.0.1" : host;
  return `http://${safeHost}:${port}`;
}

function objectArray(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((item): item is Record<string, unknown> => item != null && typeof item === "object" && !Array.isArray(item));
}

function objectValue(value: unknown): Record<string, unknown> {
  if (value != null && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return {};
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

function numberValue(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  const parsed = Number.parseInt(text(value), 10);
  return Number.isFinite(parsed) ? parsed : 0;
}
function renderThreadPanelHtml(nonce: string): string {
  return `<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8" />
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>VibeDeck 세션</title>
  <style>
    :root { color-scheme: dark; --bg: #111318; --shell: #16191f; --sidebar: #0f1218; --panel: #181b22; --panel-elevated: #1d212a; --panel-soft: #141820; --line: #2a2f3a; --line-soft: #232833; --text: #eef2ff; --muted: #9ea6b6; --accent: #7cb8ff; --accent-soft: rgba(124, 184, 255, 0.14); --accent-strong: #9dcbff; --ok: #7fd8a4; --bad: #ff8f93; --warn: #f2c66b; --focus: #7cb8ff; --font-sans: "Segoe UI", Inter, "Noto Sans KR", system-ui, sans-serif; --font-mono: Consolas, "SFMono-Regular", "Cascadia Code", monospace; }
    * { box-sizing: border-box; }
    body { margin: 0; background: radial-gradient(circle at top, #1a1f29 0%, var(--bg) 32%); color: var(--text); font-family: var(--font-sans); }
    button, textarea, select, input { font: inherit; }
    button, select, textarea, input { border: 1px solid var(--line); border-radius: 12px; background: var(--panel-soft); color: var(--text); }
    button { padding: 10px 13px; cursor: pointer; transition: background 120ms ease, border-color 120ms ease, transform 120ms ease; }
    button:hover { border-color: #394153; background: #1c212c; }
    button.primary { background: linear-gradient(180deg, #2b4f7c 0%, #23456f 100%); color: #f7fbff; border-color: #426998; font-weight: 700; }
    button.secondary { background: #1d212a; }
    button.ghost { background: transparent; }
    button.block { width: 100%; }
    textarea { width: 100%; min-height: 108px; padding: 14px; resize: vertical; background: #12161e; }
    select, input { width: 100%; padding: 10px 12px; }
    input.search { background: #0e1219; }
    details { border: 1px solid var(--line-soft); border-radius: 12px; background: #12161d; }
    summary { cursor: pointer; padding: 10px 12px; color: var(--muted); }
    pre { margin: 0; padding: 12px; background: #10141b; border: 1px solid var(--line-soft); border-radius: 12px; overflow: auto; white-space: pre-wrap; word-break: break-word; font-family: var(--font-mono); font-size: 12px; line-height: 1.55; max-height: 260px; }
    .layout { display: grid; grid-template-columns: 272px minmax(0, 1fr); min-height: 100vh; background: rgba(8, 10, 14, 0.28); }
    .main-shell { min-height: 100vh; display: grid; grid-template-rows: auto auto minmax(0, 1fr) auto; gap: 12px; background: rgba(8, 10, 14, 0.28); padding: 14px 16px; position: relative; }
    .chat-stack { min-height: 0; }
    .topbar-shell { position: sticky; top: 0; z-index: 3; }
    .topbar { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; gap: 12px; align-items: center; }
    .topbar-main { min-width: 0; display: grid; gap: 4px; }
    .topbar-title { font-size: 16px; font-weight: 700; line-height: 1.35; color: #f4f7fb; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .topbar-subtitle { color: var(--muted); font-size: 12px; line-height: 1.5; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 1; overflow: hidden; }
    .topbar-actions { display: flex; gap: 8px; align-items: center; }
    .toolbar-button { border-radius: 8px; padding: 8px 12px; background: #11151c; border: 1px solid var(--line-soft); color: #dfe6f7; font-size: 12px; }
    .toolbar-button.active { border-color: rgba(124, 184, 255, 0.35); background: #1a2230; }
    .sidebar { padding: 16px 14px; border-right: 1px solid var(--line); background: linear-gradient(180deg, #0b0e14 0%, var(--sidebar) 100%); display: grid; gap: 12px; align-content: start; }
    .main { padding: 14px 16px; display: grid; gap: 12px; align-content: start; min-width: 0; }
    .workspace-shell { display: grid; gap: 12px; align-items: start; }
    .chat-shell { display: grid; gap: 12px; min-width: 0; }
    .card { border: 1px solid var(--line); border-radius: 12px; background: #151a21; padding: 14px; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.14); }
    .card.flat { background: #151a21; box-shadow: none; }
    .stack { display: grid; gap: 12px; }
    .row { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }
    .spread { justify-content: space-between; }
    .threads, .files, .errors, .mini-list, .path-list, .timeline, .summary-strip { display: grid; gap: 10px; }
    .sidebar-top { display: grid; gap: 10px; }
    .thread { width: 100%; text-align: left; padding: 12px; border-radius: 10px; background: #12161d; }
    .thread.active { border-color: #406186; background: #182231; box-shadow: inset 0 0 0 1px rgba(124, 184, 255, 0.12); }
    .thread .thread-title { font-size: 13px; font-weight: 600; line-height: 1.45; }
    .thread .thread-meta { display: flex; justify-content: space-between; gap: 8px; margin-top: 8px; color: var(--muted); font-size: 11px; }
    .thread .thread-state { color: #b9c6d8; font-size: 11px; }
    .thread .thread-body { margin-top: 6px; color: var(--muted); font-size: 12px; line-height: 1.5; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden; }
    .muted { color: var(--muted); font-size: 12px; line-height: 1.55; }
    .eyebrow { color: var(--muted); font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; }
    .title { font-weight: 700; }
    .title.small { font-size: 14px; }
    .section-head { display: flex; justify-content: space-between; gap: 10px; align-items: flex-start; }
    .section-head .title { font-size: 13px; }
    .pill { display: inline-flex; align-items: center; gap: 6px; padding: 6px 10px; border-radius: 8px; border: 1px solid var(--line-soft); background: #11151c; color: var(--muted); font-size: 12px; }
    .pill.ok { color: var(--ok); }
    .pill.bad { color: var(--bad); }
    .pill.warn { color: var(--warn); }
    .pill.focus { color: var(--focus); }
    .badge { display: inline-flex; align-items: center; gap: 6px; padding: 4px 9px; border-radius: 8px; border: 1px solid var(--line-soft); background: #11151c; color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; }
    .badge.ok { color: var(--ok); }
    .badge.bad { color: var(--bad); }
    .badge.warn { color: var(--warn); }
    .sidebar-summary { border: 1px solid var(--line-soft); border-radius: 14px; padding: 12px; background: #11151d; }
    .composer-shell { display: grid; gap: 12px; }
    .composer-actions { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; justify-content: space-between; }
    .checkbox-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; padding: 0 12px 12px; }
    .checkbox { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
    .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
    .summary-strip { grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); }
    .summary-card, .mini-card { border: 1px solid var(--line-soft); border-radius: 10px; padding: 12px; background: #121720; min-width: 0; }
    .summary-card strong, .mini-card strong { display: block; margin-top: 4px; font-size: 13px; }
    .summary-card { background: linear-gradient(180deg, rgba(27, 32, 40, 0.98) 0%, rgba(19, 23, 30, 0.98) 100%); }
    .list-label { color: var(--muted); font-size: 11px; letter-spacing: 0.04em; text-transform: uppercase; }
    .file, .error { border: 1px solid var(--line-soft); border-radius: 10px; padding: 12px; background: #121720; }
    .head { display: flex; justify-content: space-between; gap: 10px; margin-bottom: 6px; align-items: flex-start; }
    .path-button { width: 100%; text-align: left; background: #11151c; font-family: var(--font-mono); font-size: 12px; }
    .empty { padding: 14px; border: 1px dashed var(--line); border-radius: 12px; color: var(--muted); background: #11151c; }
    .banner { display: grid; gap: 8px; }
    .notice { border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; background: #171c24; }
    .notice.error { border-color: rgba(255, 143, 147, 0.38); }
    .notice.info { border-color: rgba(124, 184, 255, 0.32); }
    .session-bar { display: grid; gap: 10px; }
    .session-bar .session-main { display: flex; justify-content: space-between; gap: 12px; align-items: flex-start; }
    .session-bar .session-title { font-size: 18px; font-weight: 700; line-height: 1.35; }
    .session-bar .session-summary { color: var(--muted); font-size: 13px; line-height: 1.6; max-width: 920px; }
    .session-meta { display: flex; flex-wrap: wrap; gap: 8px 12px; color: var(--muted); font-size: 12px; }
    .chat-panel { display: grid; gap: 12px; }
    .timeline-card { min-height: 420px; }
    .timeline { align-content: start; }
    .message { border: 1px solid var(--line-soft); border-radius: 10px; padding: 12px 14px; background: #141922; display: grid; gap: 10px; }
    .message.user { margin-left: 38px; background: #182130; border-color: rgba(105, 149, 206, 0.28); }
    .message.assistant { margin-right: 38px; background: #151920; }
    .message.system { background: #14181f; border-style: dashed; }
    .message-meta { display: flex; justify-content: space-between; gap: 12px; align-items: flex-start; }
    .message-author { display: flex; gap: 10px; align-items: flex-start; }
    .avatar { width: 24px; height: 24px; border-radius: 8px; display: inline-flex; align-items: center; justify-content: center; background: #0f131b; border: 1px solid var(--line-soft); color: var(--accent-strong); font-size: 11px; font-weight: 700; flex: none; }
    .message.user .avatar { color: #d7e9ff; border-color: rgba(105, 149, 206, 0.34); }
    .message-label { font-size: 12px; font-weight: 700; }
    .message-sub { font-size: 11px; color: var(--muted); margin-top: 2px; }
    .message-title { font-size: 13px; font-weight: 600; line-height: 1.5; }
    .message-body { color: #dfe6f7; font-size: 13px; line-height: 1.65; }
    .message-body code { font-family: var(--font-mono); }
    .message-chips { display: flex; flex-wrap: wrap; gap: 8px; justify-content: flex-end; }
    .utility-panel { display: grid; gap: 12px; }
    .utility-tabs { display: flex; flex-wrap: wrap; gap: 8px; }
    .utility-tab { border: 1px solid var(--line-soft); border-radius: 999px; padding: 8px 12px; background: #11151c; color: var(--muted); font-size: 12px; }
    .utility-tab.active { border-color: rgba(124, 184, 255, 0.35); background: rgba(47, 69, 99, 0.34); color: #e6eefb; }
    .utility-body { display: grid; gap: 10px; }
    .utility-hint { color: var(--muted); font-size: 12px; }
    .drawer-backdrop { position: fixed; inset: 0; background: rgba(5, 7, 10, 0.56); z-index: 18; }
    .panel-drawer { position: fixed; top: 10px; bottom: 10px; width: min(340px, calc(100vw - 24px)); border: 1px solid var(--line); border-radius: 12px; background: #10151c; box-shadow: 0 18px 50px rgba(0, 0, 0, 0.28); z-index: 19; display: grid; gap: 12px; align-content: start; padding: 16px; overflow: auto; }
    .panel-drawer.left { left: 10px; }
    .drawer-head { display: flex; justify-content: space-between; gap: 10px; align-items: flex-start; }
    .drawer-title { font-size: 14px; font-weight: 700; color: #f4f7fb; }
    .drawer-subtitle { color: var(--muted); font-size: 12px; line-height: 1.45; }
    .drawer-close { border-radius: 8px; padding: 6px 10px; background: #11151c; border: 1px solid var(--line-soft); color: var(--muted); font-size: 12px; }
    .drawer-content { display: grid; gap: 12px; }
    .change-card { border: 1px solid #2d3644; border-radius: 10px; background: #10161d; overflow: hidden; }
    .change-card-header { display: flex; justify-content: space-between; gap: 12px; align-items: center; padding: 12px 14px; border-bottom: 1px solid var(--line-soft); background: #111820; }
    .change-card-title { font-size: 13px; font-weight: 700; color: #eef3fb; }
    .change-card-delta { display: flex; gap: 10px; font-size: 12px; font-weight: 700; }
    .delta-plus { color: #57c67f; }
    .delta-minus { color: #f06b77; }
    .change-file-list { display: grid; }
    .change-file-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 12px; align-items: center; padding: 10px 14px; border-top: 1px solid var(--line-soft); }
    .change-file-row:first-child { border-top: 0; }
    .change-file-name { min-width: 0; font-size: 13px; line-height: 1.45; color: #eef3fb; word-break: break-all; }
    .change-file-stats { display: inline-flex; gap: 10px; font-size: 12px; font-weight: 700; }
    .change-preview { margin: 0 14px 14px; border: 1px solid #334055; border-radius: 10px; overflow: hidden; background: #0f151c; }
    .change-preview-head { display: flex; justify-content: space-between; gap: 10px; align-items: center; padding: 10px 12px; background: #121a23; border-bottom: 1px solid #334055; }
    .change-preview-title { min-width: 0; font-size: 12px; font-weight: 600; color: #eef3fb; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .change-preview-body { padding: 12px; font-family: var(--font-mono); font-size: 12px; line-height: 1.55; color: #d8e2f1; white-space: pre-wrap; word-break: break-word; }
    .change-actions { display: flex; gap: 8px; flex-wrap: wrap; padding: 0 14px 14px; }
    .timeline { align-content: start; max-height: calc(100vh - 300px); overflow: auto; padding-right: 4px; }
    @media (max-width: 1180px) { .two-col, .checkbox-grid { grid-template-columns: 1fr; } .message.user, .message.assistant { margin-left: 0; margin-right: 0; } }
    @media (max-width: 960px) { .layout { grid-template-columns: 1fr; } .sidebar { border-right: 0; border-bottom: 1px solid var(--line); } .main-shell { padding-left: 12px; padding-right: 12px; } .panel-drawer { width: calc(100vw - 20px); left: 10px; } .change-file-row { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <div id="app"><div class="card flat"><div class="title">공유 세션을 불러오는 중...</div><div class="muted">잠시 후에도 바뀌지 않으면 VibeDeck: Show Bridge Status와 패널 오류 문구를 확인하세요.</div></div></div>
  <script nonce="${nonce}">
    const appRoot = document.getElementById("app");
    function safeEsc(value) {
      return String(value || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
    }
    function renderFatalError(error) {
      if (!appRoot) {
        return;
      }
      const message = error instanceof Error ? (error.stack || error.message) : String(error || "알 수 없는 오류");
      appRoot.innerHTML = '<div class="card flat"><div class="title">패널을 그리지 못했습니다.</div><div class="muted">아래 오류를 확인해 주세요.</div><pre>' + safeEsc(message) + '</pre></div>';
    }

    window.addEventListener("error", function(event) {
      renderFatalError(event.error || event.message);
    });

    window.addEventListener("unhandledrejection", function(event) {
      renderFatalError(event.reason);
    });

    try {
    const vscode = acquireVsCodeApi();
    vscode.postMessage({ type: "ready" });
    let state = emptyState();
    let draftPrompt = "";
    let draftSyncTimer = undefined;
    let selectedRunProfileId = "";
    let threadFilter = "";
    let showThreadDrawer = false;
    let contextOptions = {
      includeActiveFile: true,
      includeSelection: false,
      includeLatestError: true,
      includeWorkspaceSummary: false,
    };

    window.addEventListener("message", function(event) {
      const message = event.data;
      if (!message || message.type !== "state") {
        return;
      }
      state = message.state;
      if (!selectedRunProfileId || !state.runProfiles.some(function(profile) { return profile.id === selectedRunProfileId; })) {
        selectedRunProfileId = state.derived.runProfileId || (state.runProfiles[0] ? state.runProfiles[0].id : "");
      }
      render();
    });

    document.addEventListener("click", function(event) {
      const target = event.target.closest("[data-action]");
      if (!target) {
        return;
      }
      const action = target.dataset.action;
      if (action === "refresh") {
        post("refresh");
        return;
      }
      if (action === "toggle-thread-drawer") {
        showThreadDrawer = !showThreadDrawer;
        render();
        return;
      }
      if (action === "close-drawers") {
        showThreadDrawer = false;
        render();
        return;
      }
      if (action === "new-thread") {
        draftPrompt = "";
        showThreadDrawer = false;
        post("new-thread");
        return;
      }
      if (action === "select-thread") {
        draftPrompt = "";
        showThreadDrawer = false;
        post("select-thread", { threadId: target.dataset.threadId || "" });
        return;
      }
      if (action === "submit-prompt") {
        const prompt = draftPrompt.trim();
        if (!prompt) {
          return;
        }
        draftPrompt = "";
        post("submit-prompt", { prompt: prompt, contextOptions: contextOptions });
        return;
      }
      if (action === "apply-patch") {
        post("apply-patch");
        return;
      }
      if (action === "run-profile") {
        post("run-profile", { profileId: selectedRunProfileId });
        return;
      }
      if (action === "open-location") {
        post("open-location", {
          path: target.dataset.path || "",
          line: Number.parseInt(target.dataset.line || "0", 10) || 0,
          column: Number.parseInt(target.dataset.column || "0", 10) || 0,
        });
      }
    });

    document.addEventListener("input", function(event) {
      const target = event.target;
      if (target && target.id === "thread-filter") {
        threadFilter = target.value;
        render();
        return;
      }
      if (target && target.id === "prompt-input") {
        draftPrompt = target.value;
        if (draftSyncTimer) {
          clearTimeout(draftSyncTimer);
        }
        draftSyncTimer = setTimeout(function() {
          post("update-draft", { prompt: draftPrompt });
        }, 250);
      }
    });

    document.addEventListener("change", function(event) {
      const target = event.target;
      if (!target) {
        return;
      }
      if (target.id === "run-profile-select") {
        selectedRunProfileId = target.value;
        return;
      }
      if (target.dataset && target.dataset.contextKey) {
        contextOptions[target.dataset.contextKey] = target.checked === true;
      }
    });

    render();

    function post(type, payload) {
      vscode.postMessage(Object.assign({ type: type }, payload || {}));
    }

    function emptyState() {
      return {
        agentBaseUrl: "http://127.0.0.1:8080",
        autoRefreshMs: 4000,
        composeMode: false,
        statusMessage: "",
        errorMessage: "",
        refreshedAt: 0,
        adapter: { name: "", mode: "", ready: false, workspaceRoot: "", binaryPath: "", notes: [] },
        runProfiles: [],
        threads: [],
        selectedThreadId: "",
        currentThread: null,
        currentJobId: "",
        events: [],
        live: { participants: [], composer: { draftText: "", isTyping: false, updatedAt: 0 }, focus: { activeFilePath: "", selection: "", patchPath: "", runErrorPath: "", runErrorLine: 0, updatedAt: 0 }, activity: { phase: "", summary: "", updatedAt: 0 }, reasoning: { title: "", summary: "", sourceKind: "", updatedAt: 0 }, plan: { summary: "", items: [], updatedAt: 0 }, tools: { currentLabel: "", currentStatus: "", activities: [], updatedAt: 0 }, terminal: { status: "", profileId: "", label: "", command: "", summary: "", excerpt: "", output: "", updatedAt: 0 }, workspace: { rootPath: "", activeFilePath: "", patchFiles: [], changedFiles: [], updatedAt: 0 } },
        operation: { currentJobId: "", phase: "", patchSummary: "", patchFileCount: 0, patchFiles: [], patchResultStatus: "", patchResultMessage: "", runProfileId: "", runLabel: "", runCommand: "", runStatus: "", runSummary: "", runExcerpt: "", runOutput: "", runChangedFiles: [], runTopErrors: [], currentJobFiles: [], lastError: "" },
        derived: { promptText: "", patchSummary: "", patchFiles: [], patchResultStatus: "", patchResultMessage: "", patchAvailabilityReason: "", currentJobFiles: [], runProfileId: "", runStatus: "", runSummary: "", runExcerpt: "", runOutput: "", runErrors: [] },
      };
    }

    function render() {
      const app = document.getElementById("app");
      if (!app) {
        return;
      }
      const promptValue = draftPrompt || (state.composeMode ? "" : (state.live.composer.draftText || state.derived.promptText));
      app.innerHTML = [
        '<div class="main-shell">',
        renderBanner(),
        '  <section class="card flat topbar-shell">' + renderTopBar() + '</section>',
        '  <section class="chat-stack">',
        '    <section class="card chat-panel timeline-card">' + renderTimeline() + '</section>',
        '  </section>',
        '  <section class="card flat">' + renderComposer(promptValue) + '</section>',
        renderThreadDrawer(),
        '</div>',
      ].join('');
    }

    function renderTopBar() {
      const title = state.composeMode ? '새 세션' : ((state.currentThread && state.currentThread.title) || '세션을 선택하세요');
      const summary = state.live.activity.summary || ((state.currentThread && state.currentThread.lastEventText) || '채팅을 시작하면 결과가 여기에 이어집니다.');
      return [
        '<div class="topbar">',
        '  <div class="topbar-actions"><button class="toolbar-button ' + (showThreadDrawer ? 'active' : '') + '" data-action="toggle-thread-drawer">세션</button></div>',
        '  <div class="topbar-main"><div class="topbar-title">' + esc(title) + '</div><div class="topbar-subtitle">' + esc(summary) + '</div></div>',
        '  <div class="topbar-actions"><button class="toolbar-button" data-action="refresh">새로고침</button><button class="toolbar-button" data-action="new-thread">새 세션</button></div>',
        '</div>',
      ].join('');
    }

    function renderThreadDrawer() {
      if (!showThreadDrawer) {
        return '';
      }
      return [
        '<button class="drawer-backdrop" data-action="close-drawers" aria-label="드로어 닫기"></button>',
        '<aside class="panel-drawer left">',
        '  <div class="drawer-head"><div><div class="drawer-title">세션</div><div class="drawer-subtitle">현재 스레드와 새 세션 시작만 여기서 관리합니다.</div></div><button class="drawer-close" data-action="close-drawers">닫기</button></div>',
        '  <div class="drawer-content">',
        '    <input id="thread-filter" class="search" placeholder="세션 검색" value="' + attr(threadFilter) + '" />',
        '    <div class="row spread"><button class="primary block" data-action="new-thread">새 세션</button><button class="ghost" data-action="refresh">새로고침</button></div>',
        '    <div class="threads">' + renderThreads() + '</div>',
        '  </div>',
        '</aside>',
      ].join('');
    }

    function renderSidebarSummary() {
      const title = state.composeMode ? '새 세션' : ((state.currentThread && state.currentThread.title) || '선택된 세션 없음');
      const activity = state.live.activity.summary || ((state.currentThread && state.currentThread.lastEventText) || '아직 작업 기록이 없습니다.');
      return [
        '<div class="eyebrow">현재 세션</div>',
        '<div class="title small">' + esc(title) + '</div>',
        '<div class="muted">' + esc(fmt((state.currentThread && state.currentThread.updatedAt) || state.refreshedAt, false)) + '</div>',
        '<div class="muted">' + esc(activity) + '</div>',
      ].join('');
    }

    function renderBanner() {
      const items = [];
      if (state.errorMessage) {
        items.push('<section class="notice error"><div class="title small">오류</div><div class="muted">' + esc(state.errorMessage) + '</div></section>');
      }
      if (!state.adapter.ready && !state.errorMessage) {
        items.push('<section class="notice"><div class="title small">연결 준비</div><div class="muted">agent가 아직 응답하지 않으면 ' + esc(state.agentBaseUrl) + ' 주소와 vibedeck_doctor.ps1 결과를 먼저 확인하세요.</div></section>');
      }
      if (!items.length) {
        return '';
      }
      return '<div class="banner">' + items.join('') + '</div>';
    }

    function renderThreads() {
      const filter = threadFilter.trim().toLowerCase();
      const threads = state.threads.filter(function(thread) {
        if (!filter) {
          return true;
        }
        return [thread.title, thread.lastEventText, thread.state, thread.id].join(' ').toLowerCase().includes(filter);
      });
      if (!threads.length) {
        return '<div class="empty">아직 생성된 스레드가 없습니다.</div>';
      }
      return threads.map(function(thread) {
        const active = !state.composeMode && thread.id === state.selectedThreadId;
        return '<button class="thread ' + (active ? 'active' : '') + '" data-action="select-thread" data-thread-id="' + attr(thread.id) + '"><div class="head"><div class="thread-title">' + esc(thread.title || thread.id) + '</div><span class="muted">' + esc(fmt(thread.updatedAt, false)) + '</span></div><div class="thread-meta"><span class="thread-state">' + esc(thread.state || '-') + '</span></div><div class="thread-body">' + esc(compactThreadPreview(thread)) + '</div></button>';
      }).join('');
    }

    function renderRunProfiles() {
      if (!state.runProfiles.length) {
        return '<option value="">프로파일 없음</option>';
      }
      return state.runProfiles.map(function(profile) {
        const label = profile.label && profile.label !== profile.id ? profile.label + ' (' + profile.id + ')' : profile.id;
        const selected = profile.id === selectedRunProfileId ? ' selected' : '';
        return '<option value="' + attr(profile.id) + '"' + selected + '>' + esc(label) + '</option>';
      }).join('');
    }

    function renderSessionHeader() {
      const title = state.composeMode ? '새 세션' : ((state.currentThread && state.currentThread.title) || '세션을 선택하세요');
      const summary = state.live.activity.summary || ((state.currentThread && state.currentThread.lastEventText) || '프롬프트를 보내 작업을 시작하세요.');
      const activeFilePath = state.live.workspace.activeFilePath || state.live.focus.activeFilePath || '';
      const terminalStatus = state.live.terminal.status || state.derived.runStatus || '';
      const changedCount = state.live.workspace.changedFiles.length || state.derived.currentJobFiles.length || 0;
      const meta = [];
      if (activeFilePath) {
        meta.push('<span>현재 파일 · ' + esc(activeFilePath) + '</span>');
      }
      if (terminalStatus) {
        meta.push('<span>실행 · ' + esc(terminalStatus) + '</span>');
      }
      if (changedCount) {
        meta.push('<span>변경 파일 · ' + esc(String(changedCount)) + '</span>');
      }
      return [
        '<div class="session-bar">',
        '  <div class="session-main">',
        '    <div class="stack">',
        '      <div class="session-title">' + esc(title) + '</div>',
        '      <div class="session-summary">' + esc(summary) + '</div>',
        '    </div>',
        '    <span class="badge ' + badgeTone(state.operation.phase || (state.currentThread && state.currentThread.state) || '-') + '">' + esc(state.operation.phase || ((state.currentThread && state.currentThread.state) || '-')) + '</span>',
        '  </div>',
        (meta.length ? '  <div class="session-meta">' + meta.join('') + '</div>' : ''),
        '</div>',
      ].join('');
    }

    function renderComposer(promptValue) {
      return [
        '<div class="composer-shell">',
        '<div class="section-head"><div><div class="title">메시지</div><div class="muted">필요한 요청만 적고 바로 보내세요.</div></div><span class="badge">' + esc(state.composeMode ? '새 세션' : '현재 세션') + '</span></div>',
        '<textarea id="prompt-input" placeholder="예: src/hello.py 파일에 간단한 스크립트를 추가해줘">' + esc(promptValue) + '</textarea>',
        '<div class="composer-actions">',
        '  <button class="primary" data-action="submit-prompt">전송</button>',
        '  <span class="utility-hint">변경사항과 실행 결과는 대화 안에서 바로 보여줍니다.</span>',
        '</div>',
        '<details><summary>고급 옵션</summary><div class="checkbox-grid">',
        renderCheckbox('includeActiveFile', '현재 파일', contextOptions.includeActiveFile),
        renderCheckbox('includeSelection', '선택 영역', contextOptions.includeSelection),
        renderCheckbox('includeLatestError', '최근 오류', contextOptions.includeLatestError),
        renderCheckbox('includeWorkspaceSummary', '작업공간 요약', contextOptions.includeWorkspaceSummary),
        '</div></details>',
        '</div>',
      ].join('');
    }

    function renderHighlights() {
      const items = [];
      if (state.live.reasoning.summary) {
        items.push('<div class="summary-card"><div class="list-label">현재 요약</div><strong>' + esc(state.live.reasoning.title || '현재 판단') + '</strong><div class="muted">' + esc(state.live.reasoning.summary) + '</div></div>');
      }
      if (state.live.plan.summary || (state.live.plan.items && state.live.plan.items.length)) {
        items.push('<div class="summary-card"><div class="list-label">다음 단계</div><strong>' + esc(state.live.plan.summary || '작업 단계') + '</strong><div class="mini-list">' + state.live.plan.items.slice(0, 3).map(function(item) { return '<div class="muted">[' + esc(item.status || '-') + '] ' + esc(item.label || item.detail || '-') + '</div>'; }).join('') + '</div></div>');
      }
      if (!items.length) {
        return '';
      }
      return '<section class="summary-strip">' + items.join('') + '</section>';
    }

    function renderReview() {
      const items = [
        '<div class="row">',
          '  <span class="pill">패치 ' + esc(state.derived.patchSummary || state.operation.patchSummary || '-') + '</span>',
          (state.derived.patchResultStatus || state.derived.patchResultMessage ? '<span class="pill ' + (String(state.derived.patchResultStatus || '').toLowerCase() === 'failed' ? 'bad' : 'ok') + '">적용 ' + esc(state.derived.patchResultStatus || '-') + '</span>' : ''),
        '</div>',
        '<div class="row"><button data-action="apply-patch"' + (state.currentJobId && state.derived.patchFiles.length ? '' : ' disabled') + '>패치 적용</button></div>',
      ];
      if (state.derived.patchResultMessage) {
        items.push('<div class="muted">' + esc(state.derived.patchResultMessage) + '</div>');
      }
      if (!state.derived.patchFiles.length) {
        items.push('<div class="empty">' + esc(state.derived.patchAvailabilityReason || '저장된 패치 파일이 없습니다.') + '</div>');
        return items.join('');
      }
      items.push('<div class="files">' + state.derived.patchFiles.map(function(file) {
        return '<details class="file"><summary><span class="title small">' + esc(file.path) + '</span> <span class="muted">' + esc(file.status || '-') + ' · 조각 ' + esc(String(file.hunks.length)) + '</span></summary><div class="stack">' + file.hunks.map(function(hunk) { return '<div class="stack"><div class="row spread"><div class="muted">' + esc(hunk.header || hunk.id) + '</div><span class="badge ' + badgeTone(hunk.risk) + '">' + esc(hunk.risk || '-') + '</span></div><pre>' + esc(hunk.diff) + '</pre></div>'; }).join('') + '</div></details>';
      }).join('') + '</div>');
      return items.join('');
    }

    function renderTerminal() {
      const status = state.live.terminal.status || state.derived.runStatus || '-';
      const summary = state.live.terminal.summary || state.derived.runSummary || '-';
      const command = state.live.terminal.command || state.operation.runCommand || '';
      const output = state.live.terminal.output || state.live.terminal.excerpt || state.derived.runOutput || state.derived.runExcerpt || '';
      const changedFiles = state.live.workspace.changedFiles.length ? state.live.workspace.changedFiles : state.derived.currentJobFiles;
      const items = [
        '<div class="row"><select id="run-profile-select">' + renderRunProfiles() + '</select><button class="secondary" data-action="run-profile"' + (state.currentJobId && selectedRunProfileId ? '' : ' disabled') + '>실행</button></div>',
        '<div class="row">',
        '  <span class="pill ' + (String(status).toLowerCase() === 'passed' ? 'ok' : (String(status).toLowerCase() === 'failed' ? 'bad' : '')) + '">상태 ' + esc(status) + '</span>',
        (state.live.terminal.profileId || state.derived.runProfileId ? '<span class="pill">프로파일 ' + esc(state.live.terminal.profileId || state.derived.runProfileId) + '</span>' : ''),
        '  <span class="pill">요약 ' + esc(summary) + '</span>',
        '</div>',
      ];
      if (command) {
        items.push('<div class="muted">명령</div><pre>' + esc(command) + '</pre>');
      }
      if (output) {
        items.push('<div class="muted">출력</div><pre>' + esc(output) + '</pre>');
      } else {
        items.push('<div class="empty">아직 실행 결과가 없습니다.</div>');
      }
      if (changedFiles.length) {
        items.push('<div class="list-label">변경 파일</div>' + renderPathButtons(changedFiles));
      }
      if (state.derived.runErrors.length) {
        items.push('<div class="list-label">상위 오류</div><div class="errors">' + state.derived.runErrors.map(function(item) {
          const location = item.path ? item.path + (item.line ? ':' + item.line : '') : '-';
          const action = item.path ? '<button data-action="open-location" data-path="' + attr(item.path) + '" data-line="' + attr(String(item.line || 0)) + '" data-column="' + attr(String(item.column || 0)) + '">열기</button>' : '';
          return '<div class="error"><div class="head"><div class="title small">' + esc(location) + '</div><div>' + action + '</div></div><div class="muted">' + esc(item.message) + '</div></div>';
        }).join('') + '</div>');
      }
      return items.join('');
    }

    function renderWorkspace() {
      const workspaceRoot = state.live.workspace.rootPath || state.adapter.workspaceRoot || '';
      const activeFile = state.live.workspace.activeFilePath || state.live.focus.activeFilePath || '';
      const patchFiles = state.live.workspace.patchFiles || [];
      const changedFiles = state.live.workspace.changedFiles || [];
      const items = ['<div class="two-col"><div class="mini-card"><div class="list-label">작업공간</div><strong>' + esc(workspaceRoot || '-') + '</strong></div><div class="mini-card"><div class="list-label">포커스</div><strong>' + esc(activeFile || state.live.focus.selection || '-') + '</strong></div></div>'];
      if (state.live.focus.selection) {
        items.push('<div class="muted">선택 영역 ' + esc(state.live.focus.selection) + '</div>');
      }
      if (activeFile) {
        items.push('<div class="list-label">현재 파일</div>' + renderPathButtons([activeFile]));
      }
      if (patchFiles.length) {
        items.push('<div class="list-label">패치 파일</div>' + renderPathButtons(patchFiles));
      }
      if (changedFiles.length) {
        items.push('<div class="list-label">변경 파일</div>' + renderPathButtons(changedFiles));
      }
      if (!workspaceRoot && !activeFile && !patchFiles.length && !changedFiles.length) {
        items.push('<div class="empty">아직 공유된 작업공간 상태가 없습니다.</div>');
      }
      return items.join('');
    }

    function renderPathButtons(paths) {
      return '<div class="path-list">' + paths.map(function(path) {
        return '<button class="path-button" data-action="open-location" data-path="' + attr(path) + '">' + esc(path) + '</button>';
      }).join('') + '</div>';
    }

    function renderTimeline() {
      const events = state.events.filter(function(item) { return shouldShowPrimaryEvent(item); });
      if (!events.length) {
        return '<div class="empty">아직 대화와 작업 로그가 없습니다.</div>';
      }
      return '<div class="timeline">' + events.map(function(item) {
        const role = normalizedRole(item);
        const headline = eventHeadline(item, role);
        const content = eventBody(item, headline);
        const attachment = renderEventAttachment(item);
        const chips = [];
        if (item.data && item.data.status) {
          chips.push('<span class="badge ' + badgeTone(item.data.status) + '">' + esc(String(item.data.status)) + '</span>');
        }
        return '<article class="message ' + role + '"><div class="message-meta"><div class="message-author"><span class="avatar">' + esc(roleGlyph(role)) + '</span><div><div class="message-label">' + esc(roleLabel(role)) + '</div><div class="message-sub">' + esc(fmt(item.at, true)) + '</div></div></div><div class="message-chips">' + chips.join('') + '</div></div>' + (headline ? '<div class="message-title">' + esc(headline) + '</div>' : '') + (content ? '<div class="message-body">' + nl2br(content) + '</div>' : '') + attachment + '</article>';
      }).join('') + '</div>';
    }

    function compactThreadPreview(thread) {
      const preview = String(thread.lastEventText || state.live.activity.summary || '').trim();
      if (preview) {
        return preview;
      }
      return '아직 기록이 없습니다.';
    }

    function shouldShowPrimaryEvent(item) {
      const kind = String(item.kind || '').toLowerCase();
      return ![
        'prompt_accepted',
        'tool_activity',
        'patch_apply',
        'run_profile',
        'session_event',
        'live_state',
        'status',
        'reasoning',
        'plan',
      ].includes(kind);
    }

    function eventHeadline(item, role) {
      const kind = String(item.kind || '').toLowerCase();
      if (role === 'user') {
        return '';
      }
      if (role === 'assistant' && ['assistant_message', 'assistant_response', 'provider_message', 'user_prompt', 'prompt_submit', 'prompt_submitted'].includes(kind)) {
        return '';
      }
      if (kind === 'patch_ready') {
        return '변경 제안';
      }
      if (kind === 'patch_applied' || kind === 'patch_result') {
        return '패치 적용 결과';
      }
      if (kind === 'run_finished' || kind === 'run_result') {
        return '실행 결과';
      }
      if (kind === 'error') {
        return '오류';
      }
      return item.title || describeKind(item.kind);
    }

    function eventBody(item, headline) {
      const kind = String(item.kind || '').toLowerCase();
      const summary = item.data && item.data.summary != null ? String(item.data.summary) : '';
      const message = item.data && item.data.message != null ? String(item.data.message) : '';
      const excerpt = item.data && item.data.excerpt != null ? String(item.data.excerpt) : '';
      if (kind === 'patch_ready') {
        return summary || item.body || '';
      }
      if (kind === 'patch_applied' || kind === 'patch_result') {
        return item.body || message || '';
      }
      if (kind === 'run_finished' || kind === 'run_result') {
        return summary || item.body || excerpt || '';
      }
      const raw = item.body || '';
      if (raw && raw !== headline) {
        return raw;
      }
      return '';
    }

    function renderEventAttachment(item) {
      const kind = String(item.kind || '').toLowerCase();
      if (kind === 'patch_ready') {
        const files = extractPatchFiles(item);
        return files.length ? renderChangeCard(files) : '';
      }
      if (kind === 'patch_applied' || kind === 'patch_result') {
        return renderPatchResultCard(item);
      }
      if (kind === 'run_finished' || kind === 'run_result') {
        return renderRunResultCard(item);
      }
      return '';
    }

    function renderChangeCard(files) {
      const stats = aggregatePatchStats(files);
      const preview = renderPatchPreview(files[0]);
      return [
        '<section class="change-card">',
        '  <div class="change-card-header">',
        '    <div class="change-card-title">' + esc(files.length + '개 파일 변경됨') + '</div>',
        '    <div class="change-card-delta"><span class="delta-plus">+' + esc(String(stats.added)) + '</span><span class="delta-minus">-' + esc(String(stats.removed)) + '</span></div>',
        '  </div>',
        '  <div class="change-file-list">' + files.map(function(file) {
          const fileStats = patchFileStats(file);
          return '<div class="change-file-row"><div class="change-file-name">' + esc(file.path || '-') + '</div><div class="change-file-stats"><span class="delta-plus">+' + esc(String(fileStats.added)) + '</span><span class="delta-minus">-' + esc(String(fileStats.removed)) + '</span></div></div>';
        }).join('') + '</div>',
        preview,
        '  <div class="change-actions"><button class="secondary" data-action="apply-patch"' + (state.currentJobId && files.length ? '' : ' disabled') + '>변경 반영</button>' + renderRunAction() + '</div>',
        '</section>',
      ].join('');
    }

    function renderPatchResultCard(item) {
      const status = String((item.data && item.data.status) || state.derived.patchResultStatus || '-');
      const message = String((item.data && item.data.message) || state.derived.patchResultMessage || item.body || '');
      return [
        '<section class="change-card">',
        '  <div class="change-card-header">',
        '    <div class="change-card-title">변경 반영 결과</div>',
        '    <div class="change-card-delta"><span class="' + (status.toLowerCase() === 'failed' ? 'delta-minus' : 'delta-plus') + '">' + esc(status) + '</span></div>',
        '  </div>',
        '  <div class="change-file-list"><div class="change-file-row"><div class="change-file-name">' + esc(message || '결과 메시지가 없습니다.') + '</div></div></div>',
        '  <div class="change-actions">' + renderRunAction() + '</div>',
        '</section>',
      ].join('');
    }

    function renderRunResultCard(item) {
      const changedFiles = normalizeStringList((item.data && item.data.changedFiles) || state.derived.currentJobFiles);
      const status = String((item.data && item.data.status) || state.derived.runStatus || '-');
      const summary = String((item.data && item.data.summary) || state.derived.runSummary || item.body || '');
      const rows = [];
      if (changedFiles.length) {
        rows.push.apply(rows, changedFiles.map(function(path) {
          return '<div class="change-file-row"><div class="change-file-name">' + esc(path) + '</div><div class="change-file-stats"><span class="delta-plus">changed</span></div></div>';
        }));
      } else if (summary) {
        rows.push('<div class="change-file-row"><div class="change-file-name">' + esc(summary) + '</div></div>');
      }
      return [
        '<section class="change-card">',
        '  <div class="change-card-header">',
        '    <div class="change-card-title">실행 결과</div>',
        '    <div class="change-card-delta"><span class="' + (status.toLowerCase() === 'failed' ? 'delta-minus' : 'delta-plus') + '">' + esc(status) + '</span></div>',
        '  </div>',
        '  <div class="change-file-list">' + rows.join('') + '</div>',
        '</section>',
      ].join('');
    }

    function renderRunAction() {
      return '<button data-action="run-profile"' + (state.currentJobId && selectedRunProfileId ? '' : ' disabled') + '>실행</button>';
    }

    function normalizeStringList(value) {
      if (Array.isArray(value)) {
        return value.filter(function(item) { return typeof item === 'string' && item.trim().length > 0; });
      }
      if (typeof value === 'string' && value.trim().length > 0) {
        return [value.trim()];
      }
      return [];
    }

    function extractPatchFiles(item) {
      const eventFiles = Array.isArray(item.data && item.data.files) ? item.data.files : [];
      if (eventFiles.length) {
        return eventFiles;
      }
      return Array.isArray(state.derived.patchFiles) ? state.derived.patchFiles : [];
    }

    function renderPatchPreview(file) {
      if (!file || !Array.isArray(file.hunks) || !file.hunks.length) {
        return '';
      }
      const previewLines = String(file.hunks[0].diff || '')
        .split(/\\r?\\n/)
        .filter(function(line) { return line.trim().length > 0; })
        .slice(0, 8)
        .join('\\n');
      if (!previewLines) {
        return '';
      }
      const stats = patchFileStats(file);
      return [
        '<div class="change-preview">',
        '  <div class="change-preview-head"><div class="change-preview-title">' + esc(file.path || '-') + '</div><div class="change-card-delta"><span class="delta-plus">+' + esc(String(stats.added)) + '</span><span class="delta-minus">-' + esc(String(stats.removed)) + '</span></div></div>',
        '  <div class="change-preview-body">' + esc(previewLines) + '</div>',
        '</div>',
      ].join('');
    }

    function aggregatePatchStats(files) {
      return files.reduce(function(acc, file) {
        const stats = patchFileStats(file);
        acc.added += stats.added;
        acc.removed += stats.removed;
        return acc;
      }, { added: 0, removed: 0 });
    }

    function patchFileStats(file) {
      const hunks = Array.isArray(file && file.hunks) ? file.hunks : [];
      let added = 0;
      let removed = 0;
      hunks.forEach(function(hunk) {
        String((hunk && hunk.diff) || '').split(/\\r?\\n/).forEach(function(line) {
          if (line.startsWith('+++') || line.startsWith('---')) {
            return;
          }
          if (line.startsWith('+')) {
            added += 1;
            return;
          }
          if (line.startsWith('-')) {
            removed += 1;
          }
        });
      });
      return { added: added, removed: removed };
    }

    function normalizedRole(item) {
      const role = String(item.role || '').toLowerCase();
      const kind = String(item.kind || '').toLowerCase();
      if (role.includes('assistant') || role.includes('agent') || role.includes('model')) {
        return 'assistant';
      }
      if (role.includes('user') || role.includes('human')) {
        return 'user';
      }
      if (kind.includes('prompt')) {
        return 'user';
      }
      if (kind.includes('assistant') || kind.includes('message') || kind.includes('reasoning')) {
        return 'assistant';
      }
      return 'system';
    }

    function roleLabel(role) {
      if (role === 'assistant') {
        return '에이전트';
      }
      if (role === 'user') {
        return '사용자';
      }
      return '시스템';
    }

    function roleGlyph(role) {
      if (role === 'assistant') {
        return 'AI';
      }
      if (role === 'user') {
        return 'ME';
      }
      return 'SYS';
    }

    function describeKind(kind) {
      const normalized = String(kind || '').toLowerCase();
      const labels = {
        user_prompt: '요청',
        prompt_submit: '요청',
        assistant_message: '응답',
        assistant_response: '응답',
        provider_message: '응답',
        reasoning: '판단',
        plan: '계획',
        tool_activity: '도구',
        patch_apply: '패치 적용',
        patch_result: '패치 결과',
        patch_review: '패치 검토',
        run_profile: '실행',
        run_result: '실행 결과',
        session_event: '세션',
        live_state: '실시간 상태',
        error: '오류',
        status: '상태',
      };
      if (labels[normalized]) {
        return labels[normalized];
      }
      return String(kind || '-').replace(/[_-]+/g, ' ');
    }

    function nl2br(value) {
      return esc(value).replace(/\\n/g, '<br />');
    }

    function renderCheckbox(key, label, checked) {
      return '<label class="checkbox"><input type="checkbox" data-context-key="' + attr(key) + '"' + (checked ? ' checked' : '') + ' /> ' + esc(label) + '</label>';
    }

    function badgeTone(value) {
      const normalized = String(value || '').toLowerCase();
      if (!normalized) {
        return '';
      }
      if (normalized.includes('pass') || normalized.includes('run') || normalized.includes('ready') || normalized.includes('review')) {
        return 'ok';
      }
      if (normalized.includes('fail') || normalized.includes('error') || normalized.includes('stalled')) {
        return 'bad';
      }
      if (normalized.includes('patch') || normalized.includes('wait') || normalized.includes('risk')) {
        return 'warn';
      }
      return '';
    }

    function fmt(value, withSeconds) {
      if (!value) {
        return '-';
      }
      const date = new Date(value);
      const hh = String(date.getHours()).padStart(2, '0');
      const mm = String(date.getMinutes()).padStart(2, '0');
      const ss = String(date.getSeconds()).padStart(2, '0');
      return withSeconds ? hh + ':' + mm + ':' + ss : hh + ':' + mm;
    }

    function esc(value) {
      return String(value || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    function attr(value) {
      return esc(value);
    }
    } catch (error) {
      renderFatalError(error);
    }
  </script>
</body>
</html>`;
}
