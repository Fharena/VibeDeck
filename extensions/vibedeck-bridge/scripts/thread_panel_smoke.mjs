import assert from "node:assert/strict";
import http from "node:http";
import { createBridgeExtensionController } from "../dist/bridgeExtensionController.js";

const streamClients = new Map();

const state = {
  adapter: {
    name: "cursor_agent_cli",
    mode: "cursor_agent_cli",
    ready: true,
    workspaceRoot: "C:/demo/workspace",
    binaryPath: "/home/demo/.local/bin/cursor-agent",
    notes: ["shared thread smoke"],
  },
  runProfiles: [
    {
      id: "smoke",
      label: "Smoke",
      command: "git status --short",
      scope: "SMALL",
      optional: false,
    },
  ],
  threads: [],
  details: new Map(),
  envelopes: [],
  openLocations: [],
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", "http://127.0.0.1");
  if (req.method === "GET" && url.pathname === "/v1/agent/runtime/adapter") {
    return json(res, 200, state.adapter);
  }
  if (req.method === "GET" && url.pathname === "/v1/agent/run-profiles") {
    return json(res, 200, { profiles: state.runProfiles });
  }
  if (req.method === "GET" && url.pathname === "/v1/agent/sessions") {
    return json(res, 200, { sessions: state.threads.map((thread) => toSessionSummary(thread)) });
  }
  if (req.method === "GET" && url.pathname.startsWith("/v1/agent/sessions/") && url.pathname.endsWith("/stream")) {
    const sessionId = decodeURIComponent(url.pathname.slice("/v1/agent/sessions/".length, -"/stream".length));
    const detail = state.details.get(sessionId);
    if (!detail) {
      return json(res, 404, { error: "session not found" });
    }
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });
    streamClients.set(res, sessionId);
    writeSessionEvent(res, detail);
    req.on("close", () => {
      streamClients.delete(res);
    });
    return;
  }
  if (req.method === "POST" && url.pathname.startsWith("/v1/agent/sessions/") && url.pathname.endsWith("/live")) {
    const sessionId = decodeURIComponent(url.pathname.slice("/v1/agent/sessions/".length, -"/live".length));
    const detail = state.details.get(sessionId);
    if (!detail) {
      return json(res, 404, { error: "session not found" });
    }
    const body = await readJson(req);
    updateLiveState(detail, body);
    broadcastSession(detail);
    return json(res, 200, toSessionDetail(detail));
  }
  if (req.method === "GET" && url.pathname.startsWith("/v1/agent/sessions/")) {
    const sessionId = decodeURIComponent(url.pathname.slice("/v1/agent/sessions/".length));
    if (!state.details.has(sessionId)) {
      return json(res, 404, { error: "session not found" });
    }
    return json(res, 200, toSessionDetail(state.details.get(sessionId)));
  }
  if (req.method === "GET" && url.pathname === "/v1/agent/threads") {
    return json(res, 404, { error: "legacy threads endpoint disabled in session smoke" });
  }
  if (req.method === "GET" && url.pathname.startsWith("/v1/agent/threads/")) {
    return json(res, 404, { error: "legacy threads endpoint disabled in session smoke" });
  }
  if (req.method === "POST" && url.pathname === "/v1/agent/envelope") {
    const body = await readJson(req);
    state.envelopes.push(body);
    if (body.type === "PROMPT_SUBMIT") {
      const threadId = "thread_panel_smoke";
      const jobId = "job_panel_smoke";
      const prompt = body.payload?.prompt || "";
      const detail = {
        thread: {
          id: threadId,
          title: prompt.split("\n")[0] || "새 스레드",
          sessionId: body.sid,
          state: "patch_ready",
          currentJobId: jobId,
          lastEventKind: "patch_ready",
          lastEventText: "notes.txt 변경 준비",
          updatedAt: Date.now(),
        },
        liveState: {
          participants: [],
          composer: { draftText: "", isTyping: false, updatedAt: 0 },
          focus: { activeFilePath: "", selection: "", patchPath: "", runErrorPath: "", runErrorLine: 0, updatedAt: 0 },
          activity: { phase: "reviewing", summary: "패널 smoke 세션 대기 중", updatedAt: Date.now() },
        },
        operationState: {
          currentJobId: jobId,
          phase: "reviewing",
          patchSummary: "notes.txt 변경 준비",
          patchResultStatus: "",
          patchResultMessage: "",
          runProfileId: "",
          runStatus: "",
          runSummary: "",
          currentJobFiles: ["notes.txt"],
          lastError: "",
        },
        events: [
          {
            id: "evt_prompt",
            threadId,
            jobId,
            kind: "prompt_submitted",
            role: "user",
            title: "프롬프트 제출",
            body: prompt,
            data: {},
            at: Date.now(),
          },
          {
            id: "evt_patch",
            threadId,
            jobId,
            kind: "patch_ready",
            role: "assistant",
            title: "패치 준비 완료",
            body: "notes.txt 변경 준비",
            data: {
              summary: "notes.txt 변경 준비",
              files: [
                {
                  path: "notes.txt",
                  status: "modified",
                  hunks: [
                    {
                      hunkId: "hunk_1",
                      header: "@@ -1 +1,2 @@",
                      diff: "+smoke-panel",
                      risk: "LOW",
                    },
                  ],
                },
              ],
            },
            at: Date.now(),
          },
        ],
      };
      state.threads = [detail.thread];
      state.details.set(detail.thread.sessionId, detail);
      return json(res, 200, {
        responses: [
          { type: "PROMPT_ACK", payload: { threadId, jobId } },
          { type: "PATCH_READY", payload: { jobId, summary: "notes.txt 변경 준비" } },
        ],
      });
    }
    if (body.type === "PATCH_APPLY") {
      const detail = findDetailByThreadId("thread_panel_smoke");
      detail.thread.state = "failed";
      detail.thread.lastEventKind = "patch_applied";
      detail.operationState.phase = "waiting_input";
      detail.operationState.patchResultStatus = "failed";
      detail.operationState.patchResultMessage = "patch apply blocked for smoke";
      detail.thread.lastEventText = "패치 적용 실패";
      detail.thread.updatedAt = Date.now();
      detail.events.push({
        id: "evt_apply",
        threadId: detail.thread.id,
        jobId: detail.thread.currentJobId,
        kind: "patch_applied",
        role: "system",
        title: "패치 적용 결과",
        body: "patch apply blocked for smoke",
        data: { status: "failed", message: "patch apply blocked for smoke" },
        at: Date.now(),
      });
      state.threads = [detail.thread];
      return json(res, 400, {
        error: "patch apply blocked for smoke",
        responses: [
          { type: "CMD_ACK", payload: { accepted: false, message: "patch apply blocked for smoke" } },
          { type: "PATCH_RESULT", payload: { status: "failed", message: "patch apply blocked for smoke" } },
        ],
      });
    }
    if (body.type === "RUN_PROFILE") {
      const detail = findDetailByThreadId("thread_panel_smoke");
      detail.thread.state = "passed";
      detail.thread.lastEventKind = "run_finished";
      detail.operationState.phase = "waiting_input";
      detail.operationState.runProfileId = body.payload?.profileId || "smoke";
      detail.operationState.runStatus = "passed";
      detail.operationState.runSummary = "smoke profile passed";
      detail.thread.lastEventText = "smoke profile passed";
      detail.thread.updatedAt = Date.now();
      detail.events.push({
        id: "evt_run",
        threadId: detail.thread.id,
        jobId: detail.thread.currentJobId,
        kind: "run_finished",
        role: "system",
        title: "실행 결과",
        body: "smoke profile passed",
        data: {
          profileId: body.payload?.profileId || "smoke",
          status: "passed",
          summary: "smoke profile passed",
          output: "base\nsmoke-panel\n",
          changedFiles: ["notes.txt"],
          topErrors: [
            {
              message: "synthetic warning",
              path: "notes.txt",
              line: 1,
              column: 1,
            },
          ],
        },
        at: Date.now(),
      });
      state.threads = [detail.thread];
      return json(res, 200, { responses: [{ type: "RUN_RESULT", payload: { status: "passed" } }] });
    }
    if (body.type === "OPEN_LOCATION") {
      state.openLocations.push(body.payload);
      return json(res, 200, { responses: [] });
    }
    return json(res, 200, { responses: [] });
  }
  json(res, 404, { error: "not found" });
});

await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
const agentBaseUrl = `http://127.0.0.1:${address.port}`;

const messages = { info: [], warn: [], error: [] };
const commandRegistry = new Map();
const panelMessages = [];
const activeEditorListeners = [];
const selectionListeners = [];
let panelMessageHandler = null;

const fakePanel = {
  title: "",
  webview: {
    html: "",
    onDidReceiveMessage(listener) {
      panelMessageHandler = listener;
      return { dispose() {} };
    },
    async postMessage(message) {
      panelMessages.push(message);
      return true;
    },
  },
  reveal() {},
  onDidDispose() {
    return { dispose() {} };
  },
  dispose() {},
};

const fakeVscode = {
  commands: {
    async executeCommand(command, ...args) {
      return await commandRegistry.get(command)(...args);
    },
    registerCommand(command, callback) {
      commandRegistry.set(command, callback);
      return { dispose() { commandRegistry.delete(command); } };
    },
    async getCommands() {
      return [...commandRegistry.keys()];
    },
  },
  window: {
    activeTextEditor: undefined,
    onDidChangeActiveTextEditor(listener) {
      activeEditorListeners.push(listener);
      return {
        dispose() {
          const index = activeEditorListeners.indexOf(listener);
          if (index >= 0) {
            activeEditorListeners.splice(index, 1);
          }
        },
      };
    },
    onDidChangeTextEditorSelection(listener) {
      selectionListeners.push(listener);
      return {
        dispose() {
          const index = selectionListeners.indexOf(listener);
          if (index >= 0) {
            selectionListeners.splice(index, 1);
          }
        },
      };
    },
    async showTextDocument() {
      return undefined;
    },
    showInformationMessage(message) {
      messages.info.push(message);
      return message;
    },
    showWarningMessage(message) {
      messages.warn.push(message);
      return message;
    },
    showErrorMessage(message) {
      messages.error.push(message);
      return message;
    },
    createStatusBarItem() {
      return { text: "", tooltip: undefined, command: undefined, show() {}, dispose() {} };
    },
    createWebviewPanel() {
      return fakePanel;
    },
  },
  workspace: {
    textDocuments: [],
    workspaceFolders: [{ uri: { fsPath: "C:/demo/workspace" } }],
    async openTextDocument(path) {
      return { fileName: path, getText() { return ""; } };
    },
    getConfiguration(section = "") {
      return {
        get(key, defaultValue) {
          const qualifiedKey = section ? `${section}.${key}` : key;
          if (qualifiedKey === "vibedeckBridge.autoStart") return false;
          if (qualifiedKey === "vibedeckBridge.mode") return "command";
          if (qualifiedKey === "vibedeckBridge.commandProvider") return "builtin_cursor_agent";
          if (qualifiedKey === "vibedeckBridge.agentBaseUrl") return agentBaseUrl;
          if (qualifiedKey === "vibedeckBridge.panelAutoRefreshMs") return 60000;
          return defaultValue;
        },
      };
    },
    onDidChangeConfiguration() {
      return { dispose() {} };
    },
  },
  env: {
    clipboard: {
      async writeText() {},
    },
  },
  statusBarAlignment: { left: 1 },
  viewColumn: { one: 1 },
};

const controller = createBridgeExtensionController(fakeVscode);
const context = { subscriptions: [] };

try {
  await controller.activate(context);
  await fakeVscode.commands.executeCommand("vibedeckBridge.openThreadPanel");
  await tick();

  assert.match(fakePanel.webview.html, /VibeDeck Threads/);
  assert.ok(panelMessages.length > 0, "panel should receive initial state");

  await panelMessageHandler({
    type: "submit-prompt",
    prompt: "Create notes.txt hello world",
    contextOptions: {
      includeActiveFile: true,
      includeSelection: false,
      includeLatestError: true,
      includeWorkspaceSummary: false,
    },
  });
  await waitFor(() => (panelMessages.at(-1)?.state?.currentJobId || "") === "job_panel_smoke");
  await waitFor(() => (panelMessages.at(-1)?.state?.live?.participants?.[0]?.participantId || "") === "cursor-panel");

  fakeVscode.window.activeTextEditor = createEditor("src/live_sync.ts", {
    start: { line: 4, character: 2 },
    end: { line: 4, character: 9 },
  });
  for (const listener of activeEditorListeners) {
    listener(fakeVscode.window.activeTextEditor);
  }
  for (const listener of selectionListeners) {
    listener({ textEditor: fakeVscode.window.activeTextEditor });
  }
  await waitFor(() => (panelMessages.at(-1)?.state?.live?.focus?.activeFilePath || "") === "src/live_sync.ts");
  await waitFor(() => (panelMessages.at(-1)?.state?.live?.workspace?.activeFilePath || "") === "src/live_sync.ts");

  await panelMessageHandler({ type: "update-draft", prompt: "shared smoke draft" });
  await waitFor(() => (panelMessages.at(-1)?.state?.live?.composer?.draftText || "") === "shared smoke draft");

  await panelMessageHandler({ type: "apply-patch" });
  await waitFor(() => (panelMessages.at(-1)?.state?.derived?.patchResultStatus || "") === "failed");
  const failedApplyState = panelMessages.at(-1).state;
  assert.equal(failedApplyState.errorMessage, "patch apply blocked for smoke");
  assert.equal(failedApplyState.derived.patchResultStatus, "failed");

  await panelMessageHandler({ type: "run-profile", profileId: "smoke" });
  await waitFor(() => (panelMessages.at(-1)?.state?.derived?.runStatus || "") === "passed");
  await panelMessageHandler({
    type: "open-location",
    path: "notes.txt",
    line: 1,
    column: 1,
  });
  await tick();

  const latestStateMessage = panelMessages.at(-1);
  assert.equal(latestStateMessage.type, "state");
  assert.equal(latestStateMessage.state.currentThread.id, "thread_panel_smoke");
  assert.equal(latestStateMessage.state.derived.runStatus, "passed");
  assert.equal(latestStateMessage.state.derived.patchFiles[0].path, "notes.txt");
  assert.deepEqual(latestStateMessage.state.derived.currentJobFiles, ["notes.txt"]);
  assert.equal(latestStateMessage.state.live.participants[0].participantId, "cursor-panel");
  assert.equal(latestStateMessage.state.live.focus.activeFilePath, "src/live_sync.ts");
  assert.equal(latestStateMessage.state.live.focus.selection, "5:3 -> 5:10");
  assert.equal(latestStateMessage.state.live.workspace.activeFilePath, "src/live_sync.ts");
  assert.equal(latestStateMessage.state.live.workspace.rootPath, "C:/demo/workspace");
  assert.deepEqual(latestStateMessage.state.live.workspace.patchFiles, ["notes.txt"]);
  assert.equal(latestStateMessage.state.live.composer.draftText, "shared smoke draft");
  assert.equal(state.envelopes.map((item) => item.type).join(","), "PROMPT_SUBMIT,PATCH_APPLY,RUN_PROFILE,OPEN_LOCATION");
  assert.equal(state.openLocations.length, 1);

  console.log(JSON.stringify({
    agentBaseUrl,
    threadId: latestStateMessage.state.currentThread.id,
    focusPath: latestStateMessage.state.live.focus.activeFilePath,
    workspaceActivePath: latestStateMessage.state.live.workspace.activeFilePath,
    liveDraft: latestStateMessage.state.live.composer.draftText,
    runStatus: latestStateMessage.state.derived.runStatus,
    patchFiles: latestStateMessage.state.derived.patchFiles.map((item) => item.path),
    envelopeTypes: state.envelopes.map((item) => item.type),
    openLocationCount: state.openLocations.length,
  }, null, 2));
} finally {
  await controller.deactivate();
  for (const disposable of [...context.subscriptions].reverse()) {
    disposable.dispose();
  }
  await new Promise((resolve) => server.close(resolve));
}

function json(res, statusCode, body) {
  res.statusCode = statusCode;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}


function toSessionSummary(thread) {
  return {
    id: thread.id,
    threadId: thread.id,
    controlSessionId: thread.sessionId,
    title: thread.title,
    provider: "cursor",
    workspaceRoot: state.adapter.workspaceRoot,
    currentJobId: thread.currentJobId,
    phase: thread.state,
    lastEventKind: thread.lastEventKind,
    lastEventText: thread.lastEventText,
    updatedAt: thread.updatedAt,
  };
}

function toSessionDetail(detail) {
  return {
    session: toSessionSummary(detail.thread),
    liveState: detail.liveState,
    operationState: detail.operationState,
    timeline: detail.events,
  };
}

function updateLiveState(detail, body) {
  if (body.participant) {
    detail.liveState.participants = [body.participant];
  }
  if (body.composer) {
    detail.liveState.composer = body.composer;
  }
  if (body.focus) {
    detail.liveState.focus = body.focus;
  }
  if (body.activity) {
    detail.liveState.activity = body.activity;
  }
  if (body.workspace) {
    detail.liveState.workspace = body.workspace;
  }
}

function writeSessionEvent(res, detail) {
  res.write(`event: session\ndata: ${JSON.stringify(toSessionDetail(detail))}\n\n`);
}

function broadcastSession(detail) {
  for (const [res, sessionId] of streamClients.entries()) {
    if (sessionId !== detail.thread.sessionId) {
      continue;
    }
    writeSessionEvent(res, detail);
  }
}

function findDetailByThreadId(threadId) {
  for (const detail of state.details.values()) {
    if (detail.thread.id === threadId) {
      return detail;
    }
  }
  throw new Error(`thread not found: ${threadId}`);
}

function createEditor(path, selection) {
  return {
    document: {
      fileName: path,
      uri: { fsPath: path },
    },
    selection,
  };
}
async function readJson(req) {
  let body = "";
  for await (const chunk of req) {
    body += chunk;
  }
  return JSON.parse(body || "{}");
}

function tick() {
  return new Promise((resolve) => setTimeout(resolve, 10));
}
async function waitFor(predicate, timeoutMs = 500) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (predicate()) {
      return;
    }
    await tick();
  }
  throw new Error("waitFor timeout");
}
