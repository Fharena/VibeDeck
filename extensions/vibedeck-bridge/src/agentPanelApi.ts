import http from "node:http";
import https from "node:https";

import type { DisposableLike } from "@vibedeck/cursor-bridge";

export interface AgentPanelAdapterRuntime {
  name: string;
  mode: string;
  ready: boolean;
  workspaceRoot: string;
  binaryPath: string;
  notes: string[];
}

export interface AgentPanelRunProfile {
  id: string;
  label: string;
  command: string;
  scope: string;
  optional: boolean;
}

export interface AgentPanelThreadSummary {
  id: string;
  title: string;
  sessionId: string;
  state: string;
  currentJobId: string;
  lastEventKind: string;
  lastEventText: string;
  updatedAt: number;
}

export interface AgentPanelThreadEvent {
  id: string;
  threadId: string;
  jobId: string;
  kind: string;
  role: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
  at: number;
}

export interface AgentPanelTimelineEventInput {
  id?: string;
  jobId?: string;
  kind: string;
  role?: string;
  title?: string;
  body?: string;
  data?: Record<string, unknown>;
  at?: number;
}

export interface AgentPanelSessionParticipant {
  participantId: string;
  clientType: string;
  displayName: string;
  active: boolean;
  lastSeenAt: number;
}

export interface AgentPanelSessionComposerState {
  draftText: string;
  isTyping: boolean;
  updatedAt: number;
}

export interface AgentPanelSessionFocusState {
  activeFilePath: string;
  selection: string;
  patchPath: string;
  runErrorPath: string;
  runErrorLine: number;
  updatedAt: number;
}

export interface AgentPanelSessionActivityState {
  phase: string;
  summary: string;
  updatedAt: number;
}

export interface AgentPanelSessionReasoningState {
  title: string;
  summary: string;
  sourceKind: string;
  updatedAt: number;
}

export interface AgentPanelSessionPlanItem {
  id: string;
  label: string;
  status: string;
  detail: string;
  updatedAt: number;
}

export interface AgentPanelSessionPlanState {
  summary: string;
  items: AgentPanelSessionPlanItem[];
  updatedAt: number;
}

export interface AgentPanelSessionToolActivity {
  kind: string;
  label: string;
  status: string;
  detail: string;
  at: number;
}

export interface AgentPanelSessionToolState {
  currentLabel: string;
  currentStatus: string;
  activities: AgentPanelSessionToolActivity[];
  updatedAt: number;
}

export interface AgentPanelSessionTerminalState {
  status: string;
  profileId: string;
  label: string;
  command: string;
  summary: string;
  excerpt: string;
  output: string;
  updatedAt: number;
}

export interface AgentPanelSessionWorkspaceState {
  rootPath: string;
  activeFilePath: string;
  patchFiles: string[];
  changedFiles: string[];
  updatedAt: number;
}

export interface AgentPanelSessionRunError {
  path: string;
  line: number;
  message: string;
}

export interface AgentPanelSessionLiveState {
  participants: AgentPanelSessionParticipant[];
  composer: AgentPanelSessionComposerState;
  focus: AgentPanelSessionFocusState;
  activity: AgentPanelSessionActivityState;
  reasoning: AgentPanelSessionReasoningState;
  plan: AgentPanelSessionPlanState;
  tools: AgentPanelSessionToolState;
  terminal: AgentPanelSessionTerminalState;
  workspace: AgentPanelSessionWorkspaceState;
}

export interface AgentPanelSessionOperationState {
  currentJobId: string;
  phase: string;
  patchSummary: string;
  patchFileCount: number;
  patchFiles: string[];
  patchResultStatus: string;
  patchResultMessage: string;
  runProfileId: string;
  runLabel: string;
  runCommand: string;
  runStatus: string;
  runSummary: string;
  runExcerpt: string;
  runOutput: string;
  runChangedFiles: string[];
  runTopErrors: AgentPanelSessionRunError[];
  currentJobFiles: string[];
  lastError: string;
}

export interface AgentPanelThreadDetail {
  thread: AgentPanelThreadSummary;
  events: AgentPanelThreadEvent[];
  liveState: AgentPanelSessionLiveState;
  operationState: AgentPanelSessionOperationState;
}

export interface AgentPanelBootstrapAdapter {
  name: string;
  mode: string;
  provider: string;
  ready: boolean;
}

export interface AgentPanelBootstrapThread {
  id: string;
  title: string;
  updatedAt: number;
  current: boolean;
}

export interface AgentPanelBootstrap {
  agentBaseUrl: string;
  signalingBaseUrl: string;
  workspaceRoot: string;
  currentThreadId: string;
  currentSessionId: string;
  adapter: AgentPanelBootstrapAdapter;
  recentThreads: AgentPanelBootstrapThread[];
}

export interface AgentPanelEnvelope {
  sid: string;
  rid: string;
  seq: number;
  ts: number;
  type: string;
  payload: Record<string, unknown>;
}

export interface AgentPanelEnvelopeResponse {
  responses: Record<string, unknown>[];
}

export interface AgentPanelApi {
  runtimeAdapter(baseUrl: string): Promise<AgentPanelAdapterRuntime>;
  bootstrap(baseUrl: string): Promise<AgentPanelBootstrap>;
  runProfiles(baseUrl: string): Promise<AgentPanelRunProfile[]>;
  sessions(baseUrl: string): Promise<AgentPanelThreadSummary[]>;
  sessionDetail(baseUrl: string, sessionId: string): Promise<AgentPanelThreadDetail>;
  subscribeSession(
    baseUrl: string,
    sessionId: string,
    onDetail: (detail: AgentPanelThreadDetail) => void,
    onError?: (error: AgentPanelApiError) => void,
  ): DisposableLike;
  updateSessionLiveState(
    baseUrl: string,
    sessionId: string,
    update: Record<string, unknown>,
  ): Promise<AgentPanelThreadDetail>;
  appendSessionTimelineEvents(
    baseUrl: string,
    sessionId: string,
    events: readonly AgentPanelTimelineEventInput[],
  ): Promise<AgentPanelThreadDetail>;
  threads(baseUrl: string): Promise<AgentPanelThreadSummary[]>;
  threadDetail(baseUrl: string, threadId: string): Promise<AgentPanelThreadDetail>;
  sendEnvelope(
    baseUrl: string,
    envelope: AgentPanelEnvelope,
  ): Promise<AgentPanelEnvelopeResponse>;
}

export class AgentPanelApiError extends Error {
  readonly statusCode: number;
  readonly responseBody: Record<string, unknown> | null;

  constructor(
    statusCode: number,
    message: string,
    responseBody: Record<string, unknown> | null = null,
  ) {
    super(message);
    this.name = "AgentPanelApiError";
    this.statusCode = statusCode;
    this.responseBody = responseBody;
  }
}

export function createAgentPanelApi(): AgentPanelApi {
  return new DefaultAgentPanelApi();
}

class DefaultAgentPanelApi implements AgentPanelApi {
  async runtimeAdapter(baseUrl: string): Promise<AgentPanelAdapterRuntime> {
    const body = await requestJson(baseUrl, "/v1/agent/runtime/adapter");
    return {
      name: text(body.name),
      mode: text(body.mode),
      ready: body.ready === true,
      workspaceRoot: text(body.workspaceRoot),
      binaryPath: text(body.binaryPath),
      notes: stringArray(body.notes),
    };
  }

  async bootstrap(baseUrl: string): Promise<AgentPanelBootstrap> {
    const body = await requestJson(baseUrl, "/v1/agent/bootstrap");
    const adapterSource = objectValue(body.adapter);
    return {
      agentBaseUrl: text(body.agentBaseUrl),
      signalingBaseUrl: text(body.signalingBaseUrl),
      workspaceRoot: text(body.workspaceRoot),
      currentThreadId: text(body.currentThreadId),
      currentSessionId: text(body.currentSessionId),
      adapter: {
        name: text(adapterSource.name),
        mode: text(adapterSource.mode),
        provider: text(adapterSource.provider),
        ready: adapterSource.ready === true,
      },
      recentThreads: objectArray(body.recentThreads).map((item) => ({
        id: text(item.id),
        title: text(item.title),
        updatedAt: numberValue(item.updatedAt),
        current: item.current === true,
      })),
    };
  }

  async runProfiles(baseUrl: string): Promise<AgentPanelRunProfile[]> {
    const body = await requestJson(baseUrl, "/v1/agent/run-profiles");
    return objectArray(body.profiles).map((item) => ({
      id: text(item.id),
      label: text(item.label),
      command: text(item.command),
      scope: text(item.scope),
      optional: item.optional === true,
    }));
  }

  async sessions(baseUrl: string): Promise<AgentPanelThreadSummary[]> {
    try {
      const body = await requestJson(baseUrl, "/v1/agent/sessions");
      return objectArray(body.sessions).map((item) => normalizeSessionSummary(item));
    } catch (error) {
      if (!(error instanceof AgentPanelApiError) || !shouldFallbackToThreads(error)) {
        throw error;
      }
      return await this.threads(baseUrl);
    }
  }

  async sessionDetail(
    baseUrl: string,
    sessionId: string,
  ): Promise<AgentPanelThreadDetail> {
    try {
      const body = await requestJson(
        baseUrl,
        `/v1/agent/sessions/${encodeURIComponent(sessionId)}`,
      );
      return normalizeSessionDetail(body);
    } catch (error) {
      if (!(error instanceof AgentPanelApiError) || !shouldFallbackToThreads(error)) {
        throw error;
      }
      return await this.threadDetail(baseUrl, sessionId);
    }
  }

  subscribeSession(
    baseUrl: string,
    sessionId: string,
    onDetail: (detail: AgentPanelThreadDetail) => void,
    onError?: (error: AgentPanelApiError) => void,
  ): DisposableLike {
    return requestSse(
      baseUrl,
      `/v1/agent/sessions/${encodeURIComponent(sessionId)}/stream`,
      (body) => {
        onDetail(normalizeSessionDetail(body));
      },
      onError,
    );
  }

  async updateSessionLiveState(
    baseUrl: string,
    sessionId: string,
    update: Record<string, unknown>,
  ): Promise<AgentPanelThreadDetail> {
    const body = await requestJson(
      baseUrl,
      `/v1/agent/sessions/${encodeURIComponent(sessionId)}/live`,
      "POST",
      update,
    );
    return normalizeSessionDetail(body);
  }

  async appendSessionTimelineEvents(
    baseUrl: string,
    sessionId: string,
    events: readonly AgentPanelTimelineEventInput[],
  ): Promise<AgentPanelThreadDetail> {
    const body = await requestJson(
      baseUrl,
      `/v1/agent/sessions/${encodeURIComponent(sessionId)}/events`,
      "POST",
      { events },
    );
    return normalizeSessionDetail(body);
  }

  async threads(baseUrl: string): Promise<AgentPanelThreadSummary[]> {
    const body = await requestJson(baseUrl, "/v1/agent/threads");
    return objectArray(body.threads).map((item) => ({
      id: text(item.id),
      title: text(item.title),
      sessionId: text(item.sessionId),
      state: text(item.state),
      currentJobId: text(item.currentJobId),
      lastEventKind: text(item.lastEventKind),
      lastEventText: text(item.lastEventText),
      updatedAt: numberValue(item.updatedAt),
    }));
  }

  async threadDetail(
    baseUrl: string,
    threadId: string,
  ): Promise<AgentPanelThreadDetail> {
    const body = await requestJson(
      baseUrl,
      `/v1/agent/threads/${encodeURIComponent(threadId)}`,
    );
    const threadSource = objectValue(body.thread);
    return {
      thread: {
        id: text(threadSource.id),
        title: text(threadSource.title),
        sessionId: text(threadSource.sessionId),
        state: text(threadSource.state),
        currentJobId: text(threadSource.currentJobId),
        lastEventKind: text(threadSource.lastEventKind),
        lastEventText: text(threadSource.lastEventText),
        updatedAt: numberValue(threadSource.updatedAt),
      },
      events: objectArray(body.events).map((item) => normalizeThreadEvent(item)),
      liveState: emptyLiveState(),
      operationState: emptyOperationState(),
    };
  }

  async sendEnvelope(
    baseUrl: string,
    envelope: AgentPanelEnvelope,
  ): Promise<AgentPanelEnvelopeResponse> {
    const body = await requestJson(baseUrl, "/v1/agent/envelope", "POST", envelope);
    return {
      responses: objectArray(body.responses),
    };
  }
}

async function requestJson(
  baseUrl: string,
  path: string,
  method = "GET",
  body?: unknown,
): Promise<Record<string, unknown>> {
  const normalizedBaseUrl = normalizeBaseUrl(baseUrl);
  const url = new URL(path, normalizedBaseUrl);
  const payload = body == null ? undefined : JSON.stringify(body);
  const transport = url.protocol === "https:" ? https : http;

  return await new Promise<Record<string, unknown>>((resolve, reject) => {
    const request = transport.request(
      url,
      {
        method,
        headers: payload
          ? {
              "Content-Type": "application/json",
              "Content-Length": Buffer.byteLength(payload).toString(),
            }
          : undefined,
      },
      (response) => {
        response.setEncoding("utf8");
        let raw = "";
        response.on("data", (chunk) => {
          raw += chunk;
        });
        response.on("end", () => {
          const statusCode = response.statusCode ?? 0;
          const decoded = decodeJsonBody(raw);
          if (statusCode < 200 || statusCode >= 300) {
            const message =
              typeof decoded.error === "string"
                ? decoded.error
                : JSON.stringify(decoded);
            reject(
              new AgentPanelApiError(
                statusCode,
                message || "agent request failed",
                decoded,
              ),
            );
            return;
          }
          resolve(decoded);
        });
      },
    );

    request.on("error", (error) => {
      reject(new AgentPanelApiError(0, error.message));
    });

    if (payload) {
      request.write(payload);
    }
    request.end();
  });
}

function requestSse(
  baseUrl: string,
  path: string,
  onBody: (body: Record<string, unknown>) => void,
  onError?: (error: AgentPanelApiError) => void,
): DisposableLike {
  const normalizedBaseUrl = normalizeBaseUrl(baseUrl);
  const url = new URL(path, normalizedBaseUrl);
  const transport = url.protocol === "https:" ? https : http;

  let closed = false;
  let responseRef: http.IncomingMessage | undefined;
  const request = transport.request(
    url,
    {
      method: "GET",
      headers: {
        Accept: "text/event-stream",
      },
    },
    (response) => {
      responseRef = response;
      response.setEncoding("utf8");

      const statusCode = response.statusCode ?? 0;
      if (statusCode < 200 || statusCode >= 300) {
        let raw = "";
        response.on("data", (chunk) => {
          raw += chunk;
        });
        response.on("end", () => {
          if (closed) {
            return;
          }
          const decoded = decodeJsonBody(raw);
          const message =
            typeof decoded.error === "string"
              ? decoded.error
              : JSON.stringify(decoded);
          onError?.(
            new AgentPanelApiError(statusCode, message || "session stream failed", decoded),
          );
        });
        return;
      }

      let buffer = "";
      response.on("data", (chunk) => {
        if (closed) {
          return;
        }
        buffer += chunk;
        buffer = buffer.replace(/\r\n/g, "\n");
        let boundary = buffer.indexOf("\n\n");
        while (boundary >= 0) {
          const frame = buffer.slice(0, boundary);
          buffer = buffer.slice(boundary + 2);
          const decoded = decodeSseFrame(frame);
          if (decoded) {
            onBody(decoded);
          }
          boundary = buffer.indexOf("\n\n");
        }
      });
      response.on("error", (error) => {
        if (closed) {
          return;
        }
        onError?.(new AgentPanelApiError(0, error.message));
      });
    },
  );

  request.on("error", (error) => {
    if (closed) {
      return;
    }
    onError?.(new AgentPanelApiError(0, error.message));
  });
  request.end();

  return {
    dispose() {
      closed = true;
      responseRef?.destroy();
      request.destroy();
    },
  };
}

function decodeSseFrame(frame: string): Record<string, unknown> | null {
  const dataLines: string[] = [];
  for (const rawLine of frame.split("\n")) {
    const line = rawLine.trimEnd();
    if (!line || line.startsWith(":")) {
      continue;
    }
    if (line.startsWith("data:")) {
      dataLines.push(line.slice(5).trimStart());
    }
  }
  if (dataLines.length === 0) {
    return null;
  }
  return decodeJsonBody(dataLines.join("\n"));
}

function normalizeSessionDetail(body: Record<string, unknown>): AgentPanelThreadDetail {
  const sessionSource = objectValue(body.session);
  return {
    thread: normalizeSessionSummary(sessionSource),
    events: objectArray(body.timeline).map((item) => normalizeThreadEvent(item)),
    liveState: normalizeLiveState(objectValue(body.liveState)),
    operationState: normalizeOperationState(objectValue(body.operationState)),
  };
}

function normalizeLiveState(value: Record<string, unknown>): AgentPanelSessionLiveState {
  const composer = objectValue(value.composer);
  const focus = objectValue(value.focus);
  const activity = objectValue(value.activity);
  const reasoning = objectValue(value.reasoning);
  const plan = objectValue(value.plan);
  const tools = objectValue(value.tools);
  const terminal = objectValue(value.terminal);
  const workspace = objectValue(value.workspace);
  return {
    participants: objectArray(value.participants).map((item) => ({
      participantId: text(item.participantId),
      clientType: text(item.clientType),
      displayName: text(item.displayName),
      active: item.active === true,
      lastSeenAt: numberValue(item.lastSeenAt),
    })),
    composer: {
      draftText: text(composer.draftText),
      isTyping: composer.isTyping === true,
      updatedAt: numberValue(composer.updatedAt),
    },
    focus: {
      activeFilePath: text(focus.activeFilePath),
      selection: text(focus.selection),
      patchPath: text(focus.patchPath),
      runErrorPath: text(focus.runErrorPath),
      runErrorLine: numberValue(focus.runErrorLine),
      updatedAt: numberValue(focus.updatedAt),
    },
    activity: {
      phase: text(activity.phase),
      summary: text(activity.summary),
      updatedAt: numberValue(activity.updatedAt),
    },
    reasoning: {
      title: text(reasoning.title),
      summary: text(reasoning.summary),
      sourceKind: text(reasoning.sourceKind),
      updatedAt: numberValue(reasoning.updatedAt),
    },
    plan: {
      summary: text(plan.summary),
      items: objectArray(plan.items).map((item) => ({
        id: text(item.id),
        label: text(item.label),
        status: text(item.status),
        detail: text(item.detail),
        updatedAt: numberValue(item.updatedAt),
      })),
      updatedAt: numberValue(plan.updatedAt),
    },
    tools: {
      currentLabel: text(tools.currentLabel),
      currentStatus: text(tools.currentStatus),
      activities: objectArray(tools.activities).map((item) => ({
        kind: text(item.kind),
        label: text(item.label),
        status: text(item.status),
        detail: text(item.detail),
        at: numberValue(item.at),
      })),
      updatedAt: numberValue(tools.updatedAt),
    },
    terminal: {
      status: text(terminal.status),
      profileId: text(terminal.profileId),
      label: text(terminal.label),
      command: text(terminal.command),
      summary: text(terminal.summary),
      excerpt: text(terminal.excerpt),
      output: text(terminal.output),
      updatedAt: numberValue(terminal.updatedAt),
    },
    workspace: {
      rootPath: text(workspace.rootPath),
      activeFilePath: text(workspace.activeFilePath),
      patchFiles: stringArray(workspace.patchFiles),
      changedFiles: stringArray(workspace.changedFiles),
      updatedAt: numberValue(workspace.updatedAt),
    },
  };
}

function normalizeOperationState(
  value: Record<string, unknown>,
): AgentPanelSessionOperationState {
  return {
    currentJobId: text(value.currentJobId),
    phase: text(value.phase),
    patchSummary: text(value.patchSummary),
    patchFileCount: numberValue(value.patchFileCount),
    patchFiles: stringArray(value.patchFiles),
    patchResultStatus: text(value.patchResultStatus),
    patchResultMessage: text(value.patchResultMessage),
    runProfileId: text(value.runProfileId),
    runLabel: text(value.runLabel),
    runCommand: text(value.runCommand),
    runStatus: text(value.runStatus),
    runSummary: text(value.runSummary),
    runExcerpt: text(value.runExcerpt),
    runOutput: text(value.runOutput),
    runChangedFiles: stringArray(value.runChangedFiles),
    runTopErrors: objectArray(value.runTopErrors).map((item) => ({
      path: text(item.path),
      line: numberValue(item.line),
      message: text(item.message),
    })),
    currentJobFiles: stringArray(value.currentJobFiles),
    lastError: text(value.lastError),
  };
}

function normalizeSessionSummary(item: Record<string, unknown>): AgentPanelThreadSummary {
  const sessionId = text(item.id);
  const threadId = text(item.threadId) || sessionId;
  return {
    id: threadId,
    title: text(item.title),
    sessionId: sessionId || threadId || "sid-vibedeck-panel",
    state: text(item.phase),
    currentJobId: text(item.currentJobId),
    lastEventKind: text(item.lastEventKind),
    lastEventText: text(item.lastEventText),
    updatedAt: numberValue(item.updatedAt),
  };
}

function normalizeThreadEvent(item: Record<string, unknown>): AgentPanelThreadEvent {
  return {
    id: text(item.id),
    threadId: text(item.threadId),
    jobId: text(item.jobId),
    kind: text(item.kind),
    role: text(item.role),
    title: text(item.title),
    body: text(item.body),
    data: objectValue(item.data),
    at: numberValue(item.at),
  };
}

function emptyLiveState(): AgentPanelSessionLiveState {
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

function emptyOperationState(): AgentPanelSessionOperationState {
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

function shouldFallbackToThreads(error: AgentPanelApiError): boolean {
  return error.statusCode === 404 || error.statusCode === 405 || error.statusCode === 501;
}

function normalizeBaseUrl(value: string): string {
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    throw new AgentPanelApiError(0, "agent base url is empty");
  }
  return trimmed.endsWith("/") ? trimmed : `${trimmed}/`;
}

function decodeJsonBody(value: string): Record<string, unknown> {
  if (value.trim().length === 0) {
    return {};
  }
  try {
    const decoded = JSON.parse(value);
    if (decoded != null && typeof decoded === "object" && !Array.isArray(decoded)) {
      return decoded as Record<string, unknown>;
    }
    return { data: decoded };
  } catch {
    return { raw: value };
  }
}

function objectArray(value: unknown): Record<string, unknown>[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .filter(
      (item): item is Record<string, unknown> =>
        item != null && typeof item === "object" && !Array.isArray(item),
    )
    .map((item) => ({ ...item }));
}

function objectValue(value: unknown): Record<string, unknown> {
  if (value != null && typeof value === "object" && !Array.isArray(value)) {
    return { ...(value as Record<string, unknown>) };
  }
  return {};
}

function stringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.map((item) => text(item)).filter((item) => item.length > 0);
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
