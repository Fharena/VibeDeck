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
  onDidReceiveMessage(listener: (message: unknown) => unknown): DisposableLike;
  postMessage(message: unknown): Promise<boolean> | Thenable<boolean>;
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
  private readonly vscode: ThreadPanelVscodeLike;
  private readonly api: AgentPanelApi;
  private panel: ThreadPanelWebviewPanelLike | undefined;
  private refreshTimer: NodeJS.Timeout | undefined;
  private refreshInFlight: Promise<void> | undefined;
  private sessionStream: DisposableLike | undefined;
  private readonly editorSyncDisposables: DisposableLike[] = [];
  private editorSyncTimer: NodeJS.Timeout | undefined;
  private sessionStreamSessionId = "";
  private selectedThreadId = "";
  private composeMode = false;
  private lastState: ThreadPanelViewState | undefined;
  private lastStatusMessage = "";
  private lastErrorMessage = "";
  private sequence = 1;

  constructor(vscodeLike: ThreadPanelVscodeLike, api: AgentPanelApi) {
    this.vscode = vscodeLike;
    this.api = api;
  }

  async openOrReveal(): Promise<void> {
    if (this.panel) {
      this.panel.reveal(this.vscode.viewColumn.one);
      await this.refresh();
      return;
    }

    const panel = this.vscode.window.createWebviewPanel(
      "vibedeckThreads",
      "VibeDeck Threads",
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
    if (!this.panel) {
      return;
    }
    await this.refresh();
  }

  dispose(): void {
    this.stopRefreshLoop();
    this.stopEditorSync();
    this.stopSessionStream();
    const panel = this.panel;
    this.panel = undefined;
    panel?.dispose();
  }

  private async refresh(): Promise<void> {
    if (!this.panel) {
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
    const panel = this.panel;
    if (!panel) {
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
      await panel.webview.postMessage({ type: "state", state });
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
      await panel.webview.postMessage({ type: "state", state });
    }
  }

  private async handleMessage(rawMessage: unknown): Promise<void> {
    const message = objectValue(rawMessage) as unknown as ThreadPanelMessage;
    try {
      switch (text(message.type)) {
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
    if (!this.panel || this.composeMode) {
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
    const panel = this.panel;
    if (!panel) {
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
    void panel.webview.postMessage({ type: "state", state: nextState });
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

  private updatePanelTitle(state: ThreadPanelViewState): void {
    if (!this.panel) {
      return;
    }
    const title = state.composeMode
      ? "새 스레드"
      : state.currentThread?.title || "Threads";
    this.panel.title = `VibeDeck: ${title}`;
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
    currentJobId: currentThread?.currentJobId || input.detail?.operationState.currentJobId || "",
    events: input.detail?.events ?? [],
    live: input.detail?.liveState ?? emptySessionLiveState(),
    operation: input.detail?.operationState ?? emptySessionOperationState(),
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
  <title>VibeDeck Threads</title>
  <style>
    :root { color-scheme: dark; --bg: #111318; --panel: #191d26; --line: #2b3240; --text: #edf1ff; --muted: #99a3c6; --accent: #f2c66b; --ok: #7ddfb0; --bad: #ff8a8a; font-family: Consolas, "SFMono-Regular", monospace; }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--text); }
    button, textarea, select, input { font: inherit; }
    button, select, textarea { border: 1px solid var(--line); border-radius: 10px; background: #0f131b; color: var(--text); }
    button { padding: 8px 12px; cursor: pointer; }
    button.primary { background: linear-gradient(135deg, var(--accent), #ff965b); color: #111318; border-color: transparent; font-weight: 700; }
    textarea { width: 100%; min-height: 120px; padding: 12px; resize: vertical; }
    select { width: 100%; padding: 10px 12px; }
    pre { margin: 0; padding: 12px; background: #0b0f15; border: 1px solid var(--line); border-radius: 10px; overflow: auto; white-space: pre-wrap; word-break: break-word; }
    .layout { display: grid; grid-template-columns: 280px 1fr; min-height: 100vh; }
    .sidebar { padding: 16px; border-right: 1px solid var(--line); }
    .main { padding: 16px; display: grid; gap: 14px; align-content: start; }
    .card { border: 1px solid var(--line); border-radius: 16px; background: var(--panel); padding: 14px; }
    .stack { display: grid; gap: 10px; }
    .row { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }
    .threads, .events, .files, .errors { display: grid; gap: 10px; }
    .thread { width: 100%; text-align: left; padding: 12px; }
    .thread.active { border-color: var(--accent); background: #232938; }
    .muted { color: var(--muted); font-size: 12px; line-height: 1.45; }
    .pill { display: inline-flex; align-items: center; gap: 6px; padding: 5px 10px; border-radius: 999px; border: 1px solid var(--line); background: #0f131b; color: var(--muted); font-size: 12px; }
    .pill.ok { color: var(--ok); }
    .pill.bad { color: var(--bad); }
    .two { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
    .empty { padding: 14px; border: 1px dashed var(--line); border-radius: 12px; color: var(--muted); }
    .checkbox { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
    .event, .file, .error { border: 1px solid var(--line); border-radius: 12px; padding: 12px; background: #0f131b; }
    .head { display: flex; justify-content: space-between; gap: 10px; margin-bottom: 6px; }
    .title { font-weight: 700; }
    @media (max-width: 960px) { .layout, .two { grid-template-columns: 1fr; } .sidebar { border-right: 0; border-bottom: 1px solid var(--line); } }
  </style>
</head>
<body>
  <div id="app"></div>
  <script nonce="${nonce}">
    const vscode = acquireVsCodeApi();
    let state = emptyState();
    let draftPrompt = "";
    let draftSyncTimer = undefined;
    let selectedRunProfileId = "";
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
      if (action === "new-thread") {
        draftPrompt = "";
        post("new-thread");
        return;
      }
      if (action === "select-thread") {
        draftPrompt = "";
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
        '<div class="layout">',
        '  <aside class="sidebar stack">',
        '    <div class="row"><button data-action="refresh">새로고침</button><button class="primary" data-action="new-thread">새 스레드</button></div>',
        '    <div class="pill">agent ' + esc(state.agentBaseUrl) + '</div>',
        '    <div class="threads">' + renderThreads() + '</div>',
        '  </aside>',
        '  <main class="main">',
        renderBanner(),
        '    <section class="card stack"><div class="title">Live Session</div>' + renderLive() + '</section>',
        '    <section class="card stack">',
        '      <div class="row">',
        '        <div class="pill ' + (state.adapter.ready ? 'ok' : 'bad') + '">adapter ' + esc(state.adapter.name || '-') + '</div>',
        '        <div class="pill">mode ' + esc(state.adapter.mode || '-') + '</div>',
        '        <div class="pill">workspace ' + esc(state.adapter.workspaceRoot || '-') + '</div>',
        '        <div class="pill">job ' + esc(state.currentJobId || '-') + '</div>',
        '      </div>',
        '      <textarea id="prompt-input" placeholder="예: src/hello.py 파일을 만들고 print(\"hello world\")만 넣어줘">' + esc(promptValue) + '</textarea>',
        '      <div class="row">',
        renderCheckbox('includeActiveFile', 'active file', contextOptions.includeActiveFile),
        renderCheckbox('includeSelection', 'selection', contextOptions.includeSelection),
        renderCheckbox('includeLatestError', 'latest error', contextOptions.includeLatestError),
        renderCheckbox('includeWorkspaceSummary', 'workspace summary', contextOptions.includeWorkspaceSummary),
        '      </div>',
        '      <div class="row">',
        '        <button class="primary" data-action="submit-prompt">프롬프트 전송</button>',
        '        <button data-action="apply-patch"' + (state.currentJobId && state.derived.patchFiles.length ? '' : ' disabled') + '>패치 전체 적용</button>',
        '        <select id="run-profile-select">' + renderRunProfiles() + '</select>',
        '        <button data-action="run-profile"' + (state.currentJobId && selectedRunProfileId ? '' : ' disabled') + '>프로파일 실행</button>',
        '      </div>',
        '    </section>',        '    <section class="two">',
        '      <div class="card stack"><div class="title">Patch Review</div>' + renderPatch() + '</div>',
        '      <div class="card stack"><div class="title">Run Output</div>' + renderRun() + '</div>',
        '    </section>',
        '    <section class="card stack"><div class="title">Timeline</div>' + renderTimeline() + '</section>',
        '  </main>',
        '</div>',
      ].join('');
    }

    function renderBanner() {
      const items = [];
      if (state.errorMessage) {
        items.push('<section class="card"><div class="title">오류</div><div class="muted">' + esc(state.errorMessage) + '</div></section>');
      }
      if (state.statusMessage) {
        items.push('<section class="card"><div class="title">상태</div><div class="muted">' + esc(state.statusMessage) + '</div></section>');
      }
      if (!state.adapter.ready && !state.errorMessage) {
        items.push('<section class="card"><div class="title">연결 준비</div><div class="muted">agent가 아직 응답하지 않으면 ' + esc(state.agentBaseUrl) + ' 주소와 go run ./cmd/agent 실행 상태를 확인하세요.</div></section>');
      }
      return items.join('');
    }

    function renderThreads() {
      if (!state.threads.length) {
        return '<div class="empty">아직 생성된 스레드가 없습니다.</div>';
      }
      return state.threads.map(function(thread) {
        const active = !state.composeMode && thread.id === state.selectedThreadId;
        return '<button class="thread ' + (active ? 'active' : '') + '" data-action="select-thread" data-thread-id="' + attr(thread.id) + '"><div class="title">' + esc(thread.title || thread.id) + '</div><div class="muted">' + esc(thread.state || '-') + ' · ' + esc(fmt(thread.updatedAt, false)) + '</div><div class="muted">' + esc(thread.lastEventText || thread.lastEventKind || '-') + '</div></button>';
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

    function renderLive() {
      const items = [
        '<div class="row">',
        '  <div class="pill">participants ' + esc(String(state.live.participants.length || 0)) + '</div>',
        '  <div class="pill">phase ' + esc(state.operation.phase || state.currentThread?.state || '-') + '</div>',
        '  <div class="pill">typing ' + esc(state.live.composer.isTyping ? 'yes' : 'no') + '</div>',
        '</div>',
      ];
      if (state.live.activity.summary) {
        items.push('<div class="muted">' + esc(state.live.activity.summary) + '</div>');
      }
      const focus = state.live.focus.activeFilePath || state.live.focus.patchPath || state.live.focus.runErrorPath || state.live.focus.selection;
      if (focus) {
        items.push('<div class="muted">focus ' + esc(focus) + '</div>');
      }
      if (state.live.composer.draftText) {
        items.push('<pre>' + esc(state.live.composer.draftText) + '</pre>');
      }
      if (!state.live.activity.summary && !focus && !state.live.composer.draftText) {
        items.push('<div class="empty">아직 공유된 live 상태가 없습니다.</div>');
      }
      return items.join('');
    }

    function renderPatch() {
      const items = ['<div class="pill">summary ' + esc(state.derived.patchSummary || '-') + '</div>'];
      if (state.derived.patchResultStatus || state.derived.patchResultMessage) {
        items.push('<div class="pill">apply ' + esc(state.derived.patchResultStatus || '-') + ' · ' + esc(state.derived.patchResultMessage || '-') + '</div>');
      }
      if (!state.derived.patchFiles.length) {
        items.push('<div class="empty">' + esc(state.derived.patchAvailabilityReason || '저장된 패치 파일이 없습니다.') + '</div>');
        return items.join('');
      }
      items.push('<div class="files">' + state.derived.patchFiles.map(function(file) {
        return '<div class="file"><div class="head"><div class="title">' + esc(file.path) + '</div><div class="muted">' + esc(file.status || '-') + '</div></div>' + file.hunks.map(function(hunk) { return '<div class="stack"><div class="muted">' + esc(hunk.header || hunk.id) + '</div><pre>' + esc(hunk.diff) + '</pre></div>'; }).join('') + '</div>';
      }).join('') + '</div>');
      return items.join('');
    }

    function renderRun() {
      const items = ['<div class="pill">status ' + esc(state.derived.runStatus || '-') + '</div>', '<div class="pill">summary ' + esc(state.derived.runSummary || '-') + '</div>'];
      if (state.derived.currentJobFiles.length) {
        items.push('<div class="muted">현재 job 기준 파일</div>');
        items.push('<div class="files">' + state.derived.currentJobFiles.map(function(path) {
          return '<div class="file"><div class="title">' + esc(path) + '</div></div>';
        }).join('') + '</div>');
      }
      if (state.derived.runOutput || state.derived.runExcerpt) {
        items.push('<pre>' + esc(state.derived.runOutput || state.derived.runExcerpt) + '</pre>');
      } else {
        items.push('<div class="empty">아직 실행 결과가 없습니다.</div>');
      }
      if (state.derived.runErrors.length) {
        items.push('<div class="errors">' + state.derived.runErrors.map(function(item) {
          const location = item.path ? item.path + (item.line ? ':' + item.line : '') : '-';
          const action = item.path ? '<button data-action="open-location" data-path="' + attr(item.path) + '" data-line="' + attr(String(item.line || 0)) + '" data-column="' + attr(String(item.column || 0)) + '">열기</button>' : '';
          return '<div class="error"><div class="head"><div class="title">' + esc(location) + '</div><div>' + action + '</div></div><div class="muted">' + esc(item.message) + '</div></div>';
        }).join('') + '</div>');
      }
      return items.join('');
    }

    function renderTimeline() {
      if (!state.events.length) {
        return '<div class="empty">선택된 스레드 이벤트가 없습니다.</div>';
      }
      return '<div class="events">' + state.events.map(function(item) {
        return '<div class="event"><div class="head"><div class="title">' + esc(item.title || item.kind) + '</div><div class="muted">' + esc(item.role || '-') + ' · ' + esc(fmt(item.at, true)) + '</div></div>' + (item.body ? '<div class="muted">' + esc(item.body) + '</div>' : '') + '<div class="muted">kind=' + esc(item.kind || '-') + (item.jobId ? ' · job=' + esc(item.jobId) : '') + '</div></div>';
      }).join('') + '</div>';
    }

    function renderCheckbox(key, label, checked) {
      return '<label class="checkbox"><input type="checkbox" data-context-key="' + attr(key) + '"' + (checked ? ' checked' : '') + ' /> ' + esc(label) + '</label>';
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
  </script>
</body>
</html>`;
}
